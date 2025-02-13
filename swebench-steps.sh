#!/bin/bash

if [[ "$#" -lt 3 ]]; then
  echo "Usage: $0 <output_folder> <num_threads> <max_samples> [target_id]"
  exit 1
else
  out_dir="$1"
  num_threads="$2"
  max_samples="$3"
  target_id="${4:-}"
fi

target_clause="${target_id:+--target_id $target_id}"
sdir=$(dirname $0)
set -x

echo "Running with ${num_threads} threads, ${max_samples} max samples, writing to ${out_dir}"

echo "1) localizing to suspicious files"
python $sdir/agentless/fl/localize.py \
  --file_level \
  --output_folder ${out_dir}/file_level \
  --num_threads $num_threads \
  --skip_existing \
  $target_clause

if [ $? -ne 0 ]; then
  exit 1
fi

echo "2) complement with embedding-based retrieval" 
python $sdir/agentless/fl/localize.py \
  --file_level \
  --irrelevant \
  --output_folder ${out_dir}/file_level_irrelevant \
  --num_threads $num_threads \
  --skip_existing \
  $target_clause

if [ $? -ne 0 ]; then
  exit 1
fi

echo "3) performing retrieval"
python $sdir/agentless/fl/retrieve.py \
  --index_type simple \
  --filter_type given_files \
  --filter_file ${out_dir}/file_level_irrelevant/loc_outputs.jsonl \
  --output_folder ${out_dir}/retrievel_embedding \
  --persist_dir embedding/swe-bench_simple \
  --num_threads $num_threads \
  $target_clause

if [ $? -ne 0 ]; then
  exit 1
fi

echo "4) merge predicted with embedding-based"
python $sdir/agentless/fl/combine.py \
  --retrieval_loc_file ${out_dir}/retrievel_embedding/retrieve_locs.jsonl \
  --model_loc_file ${out_dir}/file_level/loc_outputs.jsonl \
  --top_n 3 \
  --output_folder ${out_dir}/file_level_combined 

if [ $? -ne 0 ]; then
  exit 1
fi

echo "5) localize related elements"
python $sdir/agentless/fl/localize.py \
  --related_level \
  --output_folder ${out_dir}/related_elements \
  --top_n 3 \
  --compress_assign \
  --compress \
  --start_file ${out_dir}/file_level_combined/combined_locs.jsonl \
  --num_threads $num_threads\
  --skip_existing \
  $target_clause

if [ $? -ne 0 ]; then
  exit 1
fi

echo "6) localize to edit locations"
python $sdir/agentless/fl/localize.py \
  --fine_grain_line_level \
  --output_folder ${out_dir}/edit_location_samples \
  --top_n 3 \
  --compress \
  --temperature 0.8 \
  --num_samples 4 \
  --start_file ${out_dir}/related_elements/loc_outputs.jsonl \
  --num_threads $num_threads \
  --skip_existing \
  $target_clause

if [ $? -ne 0 ]; then
  exit 1
fi

echo "7) separate individual sets of edit locations"
python $sdir/agentless/fl/localize.py \
  --merge \
  --output_folder ${out_dir}/edit_location_individual \
  --top_n 3 \
  --num_samples 4 \
  --start_file ${out_dir}/edit_location_samples/loc_outputs.jsonl \
  $target_clause

if [ $? -ne 0 ]; then
  exit 1
fi

echo "8) generate patches"
python $sdir/agentless/repair/repair.py \
  --loc_file ${out_dir}/edit_location_individual/loc_merged_0-0_outputs.jsonl \
  --output_folder ${out_dir}/repair_sample_1 \
  --loc_interval \
  --top_n=3 \
  --context_window=10 \
  --max_samples 10  \
  --cot \
  --diff_format \
  --gen_and_process \
  --num_threads 2 \
  $target_clause

if [ $? -ne 0 ]; then
  exit 1
fi

echo "9) additional repair commands"
for i in {1..3}; do
    python $sdir/agentless/repair/repair.py \
      --loc_file ${out_dir}/edit_location_individual/loc_merged_${i}-${i}_outputs.jsonl \
      --output_folder ${out_dir}/repair_sample_$((i+1)) \
      --loc_interval \
      --top_n=3 \
      --context_window=10 \
      --max_samples 10  \
      --cot \
      --diff_format \
      --gen_and_process \
      --num_threads 2 \
      $target_clause
done

if [ $? -ne 0 ]; then
  exit 1
fi

echo "10) regression test selection"
python $sdir/agentless/test/run_regression_tests.py \
  --run_id generate_regression_tests \
  --output_file ${out_dir}/passing_tests.jsonl 

if [ $? -ne 0 ]; then
  exit 1
fi

echo "11) remove tests"
python $sdir/agentless/test/select_regression_tests.py \
  --passing_tests ${out_dir}/passing_tests.jsonl \
  --output_folder ${out_dir}/select_regression 

if [ $? -ne 0 ]; then
  exit 1
fi

echo "12) run on patches generated"
for i in {1..3}; do
  folder=${out_dir}/repair_sample_${i}
  for num in {0..9..1}; do
      run_id_prefix=$(basename $folder); 
      python $sdir/agentless/test/run_regression_tests.py \
        --regression_tests ${out_dir}/select_regression/output.jsonl \
        --predictions_path="${folder}/output_${num}_processed.jsonl" \
        --run_id="${run_id_prefix}_regression_${num}" \
        --num_workers $num_threads
  done
done

if [ $? -ne 0 ]; then
  exit 1
fi

echo "13) generate samples of reproduction tests, perform selection"
python $sdir/agentless/test/generate_reproduction_tests.py \
  --max_samples $max_samples \
  --output_folder ${out_dir}/reproduction_test_samples \
  --num_threads $num_threads 

if [ $? -ne 0 ]; then
  exit 1
fi

echo "14) execute tests on original repo"
for st in {0..36..4}; do 
  en=$((st + 3))
  echo "Processing ${st} to ${en}"
  for num in $(seq $st $en); do     
    echo "Processing ${num}"
    python $sdir/agentless/test/run_reproduction_tests.py \
      --run_id="reproduction_test_generation_filter_sample_${num}" \
      --test_jsonl="${out_dir}/reproduction_test_samples/output_${num}_processed_reproduction_test.jsonl" \
      --num_workers 6 \
      --testing
  done 
done

if [ $? -ne 0 ]; then
  exit 1
fi

echo "15) select one reproduction test per issue"
python $sdir/agentless/test/generate_reproduction_tests.py \
  --max_samples $max_samples \
  --output_folder ${out_dir}/reproduction_test_samples \
  --output_file reproduction_tests.jsonl \
  --select

if [ $? -ne 0 ]; then
  exit 1
fi

echo "16) evaluate generated patches"
folder=results/swe-bench-lite/repair_sample_1
for num in {0..9..1}; do
    run_id_prefix=$(basename $folder); 
    python $sdir/agentless/test/run_reproduction_tests.py \
      --test_jsonl ${out_dir}/reproduction_test_samples/reproduction_tests.jsonl \
      --predictions_path="${folder}/output_${num}_processed.jsonl" \
      --run_id="${run_id_prefix}_reproduction_${num}" --num_workers 10;
done

if [ $? -ne 0 ]; then
  exit 1
fi

echo "17) reranking"
python $sdir/agentless/repair/rerank.py \
  --patch_folder ${out_dir}/repair_sample_1/,${out_dir}/repair_sample_2/,${out_dir}/repair_sample_3/,${out_dir}/repair_sample_4/ \
  --num_samples $max_samples \
  --deduplicate \
  --regression \
  --reproduction

if [ $? -ne 0 ]; then
  exit 1
fi

echo "18) measure cost"
python $sdir/dev/util/cost.py --output_file example_step/output.jsonl 

