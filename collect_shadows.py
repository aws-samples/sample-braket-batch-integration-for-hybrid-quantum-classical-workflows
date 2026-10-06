import boto3, os
import pennylane as qp
from afqmc import shadow_collection
from braket.jobs import save_job_result
from braket.jobs.environment_variables import get_hyperparameters, get_job_device_arn

sfn_client = boto3.client("stepfunctions")
num_qubits = 4
os.environ["AWS_MAX_ATTEMPTS"] = "10"
os.environ["AWS_RETRY_MODE"] = "adaptive"

def main() -> None:
    print("Hybrid job started.")
    hyperparameters = get_hyperparameters()
    task_token = hyperparameters.get("TaskToken", None)
    print("Step Functions task token received." if task_token else "No task token provided; running without a Step Functions callback.")

    try:
        shadow_size = int(hyperparameters["ShadowSize"])
        shots = int(hyperparameters["Shots"])

        dev = get_pennylane_device(n_wires=num_qubits, max_parallel=shadow_size)
        print("The device is successfully loaded.")

        output, q_save = shadow_collection.run(shadow_size=shadow_size, shots=shots, device=dev)

        # savings require JSON serializable object
        save_job_result({"output": output, "Q_save": q_save})
        if task_token:
            print("Sending task success to Step Functions...")
            sfn_client.send_task_success(taskToken=task_token, output="{}")

    except Exception as e:
        print(e)
        if task_token:
            print("Sending task failure to Step Functions...")
            sfn_client.send_task_failure(taskToken=task_token, error=type(e).__name__, cause=str(e))
        raise e

    finally:
        print("Hybrid job completed.")


def get_pennylane_device(n_wires: int, max_parallel: int) -> qp.device:
    """Create Pennylane device from the `device` keyword argument of AwsQuantumJob.create().
    See https://docs.aws.amazon.com/braket/latest/developerguide/pennylane-embedded-simulators.html
    about the format of the `device` argument.

    Args:
        n_wires (int): number of qubits to initiate the local simulator.
        max_parallel (int): maximum number of tasks to run concurrently on the Braket backend.

    Returns:
        device: The Pennylane device
    """
    device_string = get_job_device_arn()
    print("Job device arn: ", device_string)
    prefix, device_name, *rest = device_string.split("/")
    if prefix == "local:pennylane":
        device = qp.device(device_name, wires=n_wires)
    else:
        device = qp.device("braket.aws.qubit", device_arn=device_string, wires=n_wires, parallel=True, max_parallel=max_parallel)
    print("Using simulator: ", device.name)
    return device