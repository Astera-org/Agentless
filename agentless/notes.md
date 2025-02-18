# Caching

    swebench.harness.run_evaluation::get_dataset_from_preds skips instances that are 
    already run, as logged in logs/run_evaluation.
    It appears that 


# How many Docker containers per issue? 

From README_swebench.md:

We can run this on all the patches generate, repeated for each repair run (i.e., by
changing `folder`):

```shell
folder=results/swe-bench-lite/repair_sample_1
for num in {0..9..1}; do
    run_id_prefix=$(basename $folder); 
    python agentless/test/run_regression_tests.py --regression_tests results/swe-bench-lite/select_regression/output.jsonl \
                                                  --predictions_path="${folder}/output_${num}_processed.jsonl" \
                                                  --run_id="${run_id_prefix}_regression_${num}" --num_workers 10;
done
```

(So, it says to call `run_regression_tests.py` 40 times).  Now, what does
run_regression_tests.py do?

Note:  args.prediction_path defined but != 'gold' -> go to line 127.
       args.load is False -> calls run_regression_for_each_instance (line 72)
       which calls `run_tests`.  Note that `run_tests` expects one patch per
       instance, and spins one Docker container for each instance.

Based on this, I believe it is the original design of Agentless to really spin 40
Docker containers per issue.

