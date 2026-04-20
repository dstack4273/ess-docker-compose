ARG SYNAPSE_IMAGE=matrixdotorg/synapse:latest
FROM ${SYNAPSE_IMAGE}
COPY synapse/requirements.txt /requirements.txt
RUN if [ -s /requirements.txt ]; then pip install --no-cache-dir -r /requirements.txt; fi
