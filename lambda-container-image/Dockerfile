# checkov:skip=CKV_DOCKER_2:The Lambda service manages the container lifecycle; a Dockerfile HEALTHCHECK is not used by Lambda.
# checkov:skip=CKV_DOCKER_3:The Lambda runtime runs the function as an unprivileged sandbox user regardless of the image's USER setting.
FROM public.ecr.aws/lambda/python:3.12

ARG SCRIPT_PATH=lambda-container-image
COPY ${SCRIPT_PATH}/requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip3 install -r requirements.txt

COPY ${SCRIPT_PATH}/collect_total_energies.py ${LAMBDA_TASK_ROOT}/

CMD [ "collect_total_energies.handler" ]