# Stage 1: Build Environment Setup
FROM nvidia/cuda:11.7.1-devel-ubuntu22.04 as builder

RUN apt-get update -y && apt-get install -y wget curl git tar bzip2 && rm -rf /var/lib/apt/lists/*

# Run as root; set HOME and WORKDIR explicitly
ENV HOME_INSTALL=/usr/local
WORKDIR $HOME_INSTALL

ENV ENV_NAME="dynamic-bind"

# Install micromamba
RUN curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj bin/micromamba
ENV PATH=$HOME_INSTALL/bin:$HOME_INSTALL/.local/bin:$PATH

# Ensure micromamba root prefix exists and is set so envs are created under $HOME_INSTALL/micromamba
ENV MAMBA_ROOT_PREFIX=$HOME_INSTALL/micromamba
RUN mkdir -p $MAMBA_ROOT_PREFIX

# Copy and create Conda environment
ENV ENV_FILE_NAME=environment.yml
COPY ./$ENV_FILE_NAME .
# create the environment under $MAMBA_ROOT_PREFIX
RUN $HOME_INSTALL/bin/micromamba env create --file $ENV_FILE_NAME && $HOME_INSTALL/bin/micromamba clean -afy --quiet

# Copy application code
COPY . $HOME_INSTALL/DynamicBind

# Stage 2: Runtime Environment
FROM nvidia/cuda:11.7.1-runtime-ubuntu22.04

# Install wget for ESM checkpoint download
RUN apt-get update -y && apt-get install -y wget && rm -rf /var/lib/apt/lists/*

# Use root user; set HOME and WORKDIR explicitly
ENV HOME_INSTALL=/usr/local
WORKDIR $HOME_INSTALL

ENV ENV_NAME="dynamic-bind"

# Copy the Conda environment and application code from the builder stage (no --chown)
COPY --from=builder $HOME_INSTALL/micromamba $HOME_INSTALL/micromamba
# Make sure copied micromamba envs and binaries are accessible to the container runtime user
# RUN chmod -R a+rx $HOME_INSTALL/micromamba || true
COPY --from=builder $HOME_INSTALL/bin $HOME_INSTALL/bin
COPY --from=builder $HOME_INSTALL/DynamicBind $HOME_INSTALL/DynamicBind
WORKDIR $HOME_INSTALL/DynamicBind

# Set the environment variables
ENV MAMBA_ROOT_PREFIX=$HOME_INSTALL/micromamba
ENV PATH=$HOME_INSTALL/bin:$HOME_INSTALL/.local/bin:$PATH
RUN micromamba shell init -s bash --root-prefix $MAMBA_ROOT_PREFIX

# Expose ports for streamlit and gradio
EXPOSE 7860 8501
# Workarounds for MKL / libgomp conflicts and to make numpy/mkl behave
# when using Intel MKL inside the container. This helps avoid errors such as:
# "MKL_THREADING_LAYER=INTEL is incompatible with libgomp.so.1"
ENV MKL_SERVICE_FORCE_INTEL=1
ENV MKL_THREADING_LAYER=GNU

# Ensure micromamba shell setup is available for interactive shells (kept)
RUN micromamba shell hook -s bash > /etc/profile.d/mamba.sh || true
RUN ln -sf ${MAMBA_ROOT_PREFIX}/bin/micromamba /usr/local/bin/mamba || true

# Create a minimal micromamba/conda config and pkgs dir so libmamba
# finds expected paths and emits far fewer backtraces when libraries
# or scripts invoke mamba/micromamba at runtime.
RUN mkdir -p /usr/local/micromamba/pkgs /usr/local/micromamba/envs && \
		cat > /usr/local/micromamba/.condarc <<'YAML'
channels:
	- defaults
envs_dirs:
	- /usr/local/micromamba/envs
pkgs_dirs:
	- /usr/local/micromamba/pkgs
root_prefix: /usr/local/micromamba
YAML

RUN chmod -R a+rwX /usr/local/micromamba || true

# Default command: run the python binary directly from the created environment.
# This avoids invoking micromamba/mamba at runtime (which produced libmamba logs
# about missing configuration/envs in your logs). Adjust the path if your
# env name differs. Using the env python executable sidesteps libmamba.
CMD ["/usr/local/micromamba/envs/dynamicbind/bin/python", "utils/print_device.py"]