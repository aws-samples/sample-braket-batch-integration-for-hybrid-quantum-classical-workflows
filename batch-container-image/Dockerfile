# checkov:skip=CKV_DOCKER_2:Run-to-completion AWS Batch job; ECS does not use the Dockerfile HEALTHCHECK and the job's exit code reports success or failure.
# checkov:skip=CKV_DOCKER_3:Accepted for the sample: the short-lived job container runs with the least-privilege BatchJobRole (data bucket only). See SECURITY.md.
FROM public.ecr.aws/docker/library/python:3.12

ARG SCRIPT_PATH=/batch-container-image
ARG WORKDIR=/usr/local/workspace
RUN mkdir -p ${WORKDIR}

WORKDIR ${WORKDIR}
COPY ${SCRIPT_PATH}/requirements.txt .
RUN pip install -r requirements.txt

COPY ${SCRIPT_PATH}/../../afqmc ${WORKDIR}/afqmc/
COPY ${SCRIPT_PATH}/collect_local_energies.py .

ENTRYPOINT ["python", "collect_local_energies.py"]
