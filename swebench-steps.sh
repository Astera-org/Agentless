#!/bin/bash

# This file is just a simple and crude shell-ification of the steps illustrated in
# README_swebench.md.  Those 18-ish steps are all individual python scripts which
# produce and consume intermediate files in a directory structure.
# All files will be written to sub-directories of <out_dir>

if [[ "$#" -lt 4 ]]; then
  echo "Usage: $0 <out_dir> <num_threads> <start_step> <end_step> <backend> <model> [target_id]"
  exit 1
else
  out_dir="$1"
  num_threads="$2"
  start_step=$(($3))
  end_step=$(($4))
  backend="$5"
  model="$6"
  target_id="${7:-}"
fi

if [ -z "${OPENAI_API_KEY}" ]; then
  echo "Please export env var OPENAI_API_KEY"
  exit 1
fi

if [ -z "${PYTHONPATH}" ]; then
  echo "Please add this directory to PYTHONPATH"
  exit 1
fi

NUM_PATCHES=10
NUM_EDIT_LOCATIONS=4
NUM_TESTS_PER_REPAIR=10
NUM_TOTAL_TESTS=$((NUM_EDIT_LOCATIONS * NUM_TESTS_PER_REPAIR))


target_clause="${target_id:+--target_id $target_id}"
instance_clause="${target_id:+--instance_ids $target_id}"
sdir=$(dirname $0)
# set -x

echo "Running with ${num_threads} threads, writing to ${out_dir}"

echo "killing any stuck docker containers from previous runs"
docker ps -q -a --filter "name=^sweb.eval" | xargs -r docker stop | xargs -r docker rm


if [[ $start_step -le 1 && 1 -le $end_step ]]; then
  echo "1) localizing to suspicious files"
  python $sdir/agentless/fl/localize.py \
    --model $model \
    --backend $backend \
    --file_level \
    --output_folder ${out_dir}/01_file_level \
    --num_threads $num_threads \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 2 && 2 -le $end_step ]]; then
  echo "2) complement with embedding-based retrieval" 
  python $sdir/agentless/fl/localize.py \
    --model $model \
    --backend $backend \
    --file_level \
    --irrelevant \
    --output_folder ${out_dir}/02_file_level_irrelevant \
    --num_threads $num_threads \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 3 && 3 -le $end_step ]]; then
  echo "3) performing retrieval"
  python $sdir/agentless/fl/retrieve.py \
    --index_type simple \
    --filter_type given_files \
    --filter_file ${out_dir}/02_file_level_irrelevant/loc_outputs.jsonl \
    --output_folder ${out_dir}/03_retrieval_embedding \
    --persist_dir embedding/swe-bench_simple \
    --num_threads $num_threads \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 4 && 4 -le $end_step ]]; then
  echo "4) merge predicted with embedding-based"
  python $sdir/agentless/fl/combine.py \
    --retrieval_loc_file ${out_dir}/03_retrieval_embedding/retrieve_locs.jsonl \
    --model_loc_file ${out_dir}/01_file_level/loc_outputs.jsonl \
    --top_n 3 \
    --output_folder ${out_dir}/04_file_level_combined 

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 5 && 5 -le $end_step ]]; then
  echo "5) localize related elements"
  python $sdir/agentless/fl/localize.py \
    --backend $backend \
    --model $model \
    --related_level \
    --output_folder ${out_dir}/05_related_elements \
    --top_n 3 \
    --compress_assign \
    --compress \
    --start_file ${out_dir}/04_file_level_combined/combined_locs.jsonl \
    --num_threads $num_threads \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 6 && 6 -le $end_step ]]; then
  echo "6) localize to edit locations"
  python $sdir/agentless/fl/localize.py \
    --backend $backend \
    --model $model \
    --fine_grain_line_level \
    --output_folder ${out_dir}/06_edit_location_samples \
    --top_n 3 \
    --compress \
    --temperature 0.8 \
    --num_samples $NUM_EDIT_LOCATIONS \
    --start_file ${out_dir}/05_related_elements/loc_outputs.jsonl \
    --num_threads $num_threads \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

# Produces 07_edit_location_individual/loc_merged_{i}-{j}_outputs.jsonl
# Produces 07_edit_location_individual/loc_outputs.jsonl
if [[ $start_step -le 7 && 7 -le $end_step ]]; then
  echo "7) separate individual sets of edit locations"
  python $sdir/agentless/fl/localize.py \
    --backend $backend \
    --model $model \
    --merge \
    --output_folder ${out_dir}/07_edit_location_individual \
    --top_n 3 \
    --num_samples $NUM_EDIT_LOCATIONS \
    --start_file ${out_dir}/06_edit_location_samples/loc_outputs.jsonl \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

# Produces 08_repair_sample_{i}/output_{s}_processed.jsonl
# Produces 08_repair_sample_{i}/used_locs.jsonl 
# Appends 08_repair_sample_{i}/output.jsonl
# TODO
if [[ $start_step -le 8 && 8 -le $end_step ]]; then
  # set -x
  echo "8) generate patches"
  for i in $(seq 1 $NUM_EDIT_LOCATIONS); do
      j=$((i-1))
      python $sdir/agentless/repair/repair.py \
        --backend $backend \
        --model $model \
        --loc_file ${out_dir}/07_edit_location_individual/loc_merged_${j}-${j}_outputs.jsonl \
        --output_folder ${out_dir}/08_repair_sample_${i} \
        --loc_interval \
        --top_n=3 \
        --context_window=10 \
        --max_samples $NUM_PATCHES \
        --cot \
        --diff_format \
        --gen_and_process \
        --num_threads 2 \
        $target_clause
  done

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi


if [[ $start_step -le 9 && 9 -le $end_step ]]; then
  echo "9) regression test selection"
  python $sdir/agentless/test/run_regression_tests.py \
    --run_id generate_regression_tests \
    --output_file ${out_dir}/09_passing_tests.jsonl \
    --num_workers $num_threads \
    $instance_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 10 && 10 -le $end_step ]]; then
  echo "10) remove tests"
  python $sdir/agentless/test/select_regression_tests.py \
    --backend $backend \
    --model $model \
    --passing_tests ${out_dir}/09_passing_tests.jsonl \
    --output_folder ${out_dir}/10_select_regression \
    $instance_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi


# Produces 08_repair_sample_{i}/output_{s}_regression_test_results.jsonl
if [[ $start_step -le 11 && 11 -le $end_step ]]; then
  echo "11) run regression tests on patches generated"
  for i in $(seq 1 $NUM_EDIT_LOCATIONS); do
    folder=${out_dir}/08_repair_sample_${i}
    for num in $(seq 0 $((NUM_TESTS_PER_REPAIR-1))); do
        run_id_prefix=$(basename $folder); 
        python $sdir/agentless/test/run_regression_tests.py \
          --regression_tests ${out_dir}/10_select_regression/output.jsonl \
          --predictions_path="${folder}/output_${num}_processed.jsonl" \
          --run_id="${run_id_prefix}_regression_${num}" \
          --num_workers $num_threads \
          $instance_clause
    done
  done

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 12 && 12 -le $end_step ]]; then
  echo "12) generate samples of reproduction tests, perform selection"
  python $sdir/agentless/test/generate_reproduction_tests.py \
    --backend $backend \
    --model $model \
    --max_samples $NUM_TOTAL_TESTS \
    --output_folder ${out_dir}/12_reproduction_test_samples \
    --num_threads $num_threads \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

# Produces # 12_reproduction_test_samples/output_{i}_processed_reproduction_test_verified.jsonl
# The swebench cache at `logs/run_evaluation` interferes with this.
if [[ $start_step -le 13 && 13 -le $end_step ]]; then
  echo "13) execute tests on original repo"
  for num in $(seq 0 $((NUM_TOTAL_TESTS-1))); do 
    echo "Processing ${num}"
    python $sdir/agentless/test/run_reproduction_tests.py \
      --run_id="reproduction_test_generation_filter_sample_${num}" \
      --test_jsonl="${out_dir}/12_reproduction_test_samples/output_${num}_processed_reproduction_test.jsonl" \
      --num_workers $num_threads \
      --testing \
      $instance_clause
  done 

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 14 && 14 -le $end_step ]]; then
  echo "14) select one reproduction test per issue"
  python $sdir/agentless/test/generate_reproduction_tests.py \
    --backend $backend \
    --model $model \
    --max_samples $NUM_TOTAL_TESTS \
    --output_folder ${out_dir}/12_reproduction_test_samples \
    --output_file reproduction_tests.jsonl \
    --select \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 15 && 15 -le $end_step ]]; then
  echo "15) evaluate generated patches"
  for i in $(seq 1 $NUM_EDIT_LOCATIONS); do
    folder=${out_dir}/08_repair_sample_${i}
    for num in $(seq 0 $((NUM_TESTS_PER_REPAIR-1))); do
        run_id_prefix=$(basename $folder); 
        python $sdir/agentless/test/run_reproduction_tests.py \
          --test_jsonl ${out_dir}/12_reproduction_test_samples/reproduction_tests.jsonl \
          --predictions_path="${folder}/output_${num}_processed.jsonl" \
          --run_id="${run_id_prefix}_reproduction_${num}" \
          --num_workers $num_threads \
          $instance_clause
    done
  done

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi


if [[ $start_step -le 16 && 16 -le $end_step ]]; then
  echo "16) reranking"
  pf=$(seq 1 $NUM_EDIT_LOCATIONS | sed "s%^%${out_dir}/08_repair_sample_%" | paste -sd "," -)
  python $sdir/agentless/repair/rerank.py \
    --patch_folder $pf \
    --num_samples $NUM_TOTAL_TESTS \
    --deduplicate \
    --regression \
    --reproduction \
    --output_file ${out_dir}/all_preds.jsonl \
    $target_clause

  if [ $? -ne 0 ]; then
    exit 1
  fi
fi

if [[ $start_step -le 17 && 17 -le $end_step ]]; then
  echo "17) measure cost"
  python $sdir/dev/util/cost.py --output_file example_step/output.jsonl 
fi

