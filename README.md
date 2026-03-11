# incus-mig-script

A script to automate the creation of incus Ubuntu containers using NVIDIA GPUs, optionally attaching a NVIDIA MIG or a full NVIDIA PCI express attached GPU.

This script requires that you have incus installed and configured. You must have the CUDA toolkit installed on the incus server and you need to have configured at least one MIG device (using mig-manager) before running the script if you wish to use the -g option. This script uses pwgen to generate passwords.

You will need to adjust the Network Default variables to match your network before running this script. In order for the auto IP address assignment code to work properly, all of your containers must be running when you create a new container to avoid IP address conflicts, or at least you should start the container that has the highest value for its last octet. incus-mig.sh also configures snapshots (one every 12 hours), installs openssh-server and configures a password for the root user.

incus-cleanup.sh should be configured to be run via a daily root cron job to disable and delete old containers. gpu-stats.py can be run via cron to log NVIDIA GPU activity via nvitop.

Do not use dots or any other punctuation for container names.

## Using the -n (NO_GPU_DETACH) option

This script presumes that all of your free MIG GPUs have the same configuration hence it just attaches any unused MIG GPU to the new container when you use the -g option. Therefore, if you have have some MIG GPUs using a different MIG profile to the bulk of your MIG GPUs, you should assign those GPUs to containers before running this script with the -g option so that this script doesn't attempt to assign the different spec MIG GPUs to new containers when you use the -g option.

When you are creating a container that will use a MIG GPU that you don't want to be auto-assigned by the incus-mig script, you should create the container using -n (NO_GPU_DETACH) and without using the -g arguments and then manually attach the GPU to the container. Using -n will set NO_GPU_DETACH to true and it will prevent the cleanup script from detaching the GPU from the container when it gets disabled on its expiry date and prevent it being added into the pool of available GPUs. By default, the cleanup script will detach GPUs from containers on their expiry date so that they may be used by new containers and it does not automatically delete containers using NO_GPU_DETACH.

## gpu-stats.py

gpu-stats.py can be run to generate NVIDIA GPU stat log files using nvitop for all active MIG and non-MIG enabled GPUs.

* Create the virtual environment
```
python3 -m venv /root/gpu-env
```

* Install nvitop specifically into that environment
```
/root/gpu-env/bin/pip install nvitop
```
* Run your script using the environment's python
```
/root/gpu-env/bin/python3 /root/gpu-env/bin/gpu-stats.py
```

 Adjust that last path to point to wherever you copied gpu-stats.py.
 
## incus logging
 
The incus documentation [recommends setting up a Prometheus server](https://linuxcontainers.org/incus/docs/main/metrics/) for monitoring incus metrics but if you don't need to capture every incus metric or you don't have the resources to also run a Prometheus server you could instead create a root cron job like this:
 
```
* * * * * /usr/bin/incus list status=running -f csv -c n4Dmu,devices:gpu0.mig.uuid,devices:gpu0.pci | /usr/bin/awk -v ts="$(date '+%Y-%m-%d %H:%M:%S')" '{ print ts "," $0 }' >> /var/log/incus/incus-stats.log
```

This wil log the memory, CPU, used disk space and IP address of all running incus containers. It will also log either the MIG UUID or PCI ID if a gpu is attached to a container as device ID gpu0.
