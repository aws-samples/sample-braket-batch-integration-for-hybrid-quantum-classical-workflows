import boto3, json, os, sys, tarfile
from afqmc import classical_afqmc, quantum_afqmc


def setup_and_run(entry_point, delta_tau, time_steps, input_file_key):
    """
    This method runs the user code.
    """
    print(f"Running container script with arguments: entry_point={entry_point}, delta_tau={delta_tau}, time_steps={time_steps}, input_file_key={input_file_key}")
    s3_client = boto3.client("s3")

    job_id = os.getenv("AWS_BATCH_JOB_ID")
    print(f"Job ID: {job_id}")

    s3_bucket_name = os.getenv("JOB_S3_BUCKET_NAME")
    output_file_name = os.getenv("JOB_OUTPUT_FILE_NAME")
    array_index = os.getenv("AWS_BATCH_JOB_ARRAY_INDEX", default=None)
    print(f"Array index: {array_index}")

    # Run algorithm
    result = {}
    if entry_point == "classical_afqmc":
        result = classical_afqmc.run(time_steps=time_steps, delta_tau=delta_tau, num_walkers=1)
    elif entry_point == "qc_afqmc":
        s3_client.download_file(s3_bucket_name, input_file_key, "model.tar.gz")
        with tarfile.open("model.tar.gz", "r:gz") as tar:
            tar.extractall("inputs", filter="data")
        file_path = "inputs/results.json"
        json.dump(json.load(open(file_path))["dataDictionary"], open(file_path, "w"))
        print("The matchgate shadows are successfully retrieved from S3.")

        result = quantum_afqmc.run(time_steps=time_steps, delta_tau=delta_tau, shadows_file_path=file_path, num_walkers=1)

    # Save result to output
    output_path = os.path.join(os.getcwd(), output_file_name)
    print(f"Save result to output path: {output_path}")
    with open(output_path, "w") as f:
        json.dump(result, f)

    # Upload results to S3
    if array_index:
        parent_job_id, _, child_job_index = job_id.partition(":")
        print(f"Parent job id: {parent_job_id}, child job index: {child_job_index}, job array: {array_index}")
        s3_key = os.path.join("batch", parent_job_id, child_job_index, output_file_name)
    else:
        s3_key = os.path.join("batch", job_id, output_file_name)
    print(f"Upload result to S3 with object key {s3_key}")
    s3_client.upload_file(output_file_name, s3_bucket_name, s3_key)
    print("Job completed.")


if __name__ == "__main__":
    print(f"Command line arguments: {sys.argv}")
    setup_and_run(
        entry_point=(sys.argv[3]),
        delta_tau=(float(sys.argv[4])),
        time_steps=(int(sys.argv[5])),
        input_file_key=sys.argv[6] if len(sys.argv) > 6 else None
    )
