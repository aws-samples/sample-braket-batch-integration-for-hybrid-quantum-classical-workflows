import boto3, os, json
import numpy as np

s3_client = boto3.client("s3")

def handler(event, context):
    batch_job_id = event.get("BatchJobId")
    batch_job_array_size = event.get("BatchJobArraySize")
    s3_bucket_name = os.getenv("DATA_BUCKET_NAME")

    print(f"Downloading data from S3 bucket s3:://{s3_bucket_name}/batch/{batch_job_id}/*")

    # fetch results from s3
    for i in range(batch_job_array_size):
        s3_client.download_file(
            s3_bucket_name,
            f"batch/{batch_job_id}/{i}/results.json",
            f"/tmp/result_{i}.json"  # nosec B108 - /tmp is the only writable path in Lambda and is private to the execution environment
        )
    print('All the results are saved in /tmp.')

    # perform averaging
    local_energies_real = []
    local_energies_imag = []
    weights = []

    for i in range(batch_job_array_size):
        with open(f"/tmp/result_{i}.json", "r") as file:  # nosec B108 - Lambda /tmp, see above
            data = json.load(file)
        [local_energies_real.append(j) for j in data["local_energies_real"]]
        [local_energies_imag.append(j) for j in data["local_energies_imag"]]
        [weights.append(j) for j in data["weights"]]

    local_energies = [[ii + 1.j * jj for ii, jj in zip(i, j)] for i, j in zip(local_energies_real, local_energies_imag)]
    energies = np.real(np.average(local_energies, weights=weights, axis=0))

    # upload results to s3
    final_result = {
        "energies": energies.tolist()
    }
    print('The average energies are computed.')

    with open("/tmp/final_result.json", "w") as f:  # nosec B108 - Lambda /tmp, see above
        json.dump(final_result, f)

    s3_client.upload_file("/tmp/final_result.json", s3_bucket_name, "lambda/final_result.json")  # nosec B108 - Lambda /tmp, see above
