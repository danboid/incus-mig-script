# incus-mig

incus-mig automates the creation of Debian and Ubuntu incus containers, focusing on making it easy to attach a NVIDIA MIG or a full NVIDIA PCI express GPU although doing that is optional.

This script requires root access and has to be run on an incus server that has been configured to use an incus managed network bridge interface, created and managed (DHCP and DNS) by incus.

You must have the CUDA toolkit installed on the incus server and you need to have configured at least one MIG device (using mig-manager) before running the script if you wish to use the -g option to attach a MIG GPU. You should be able to use -G without any MIG, to do PCIe passthrough of a full GPU.

incus-mig.sh also configures incus snapshots (one every 12 hours), installs openssh-server and configures a password for the root user.

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

## Example commands

Create a Ubuntu incus container called Jim-Smith with no GPU attached and using the default spec defined within the script (900GB HD, 32GB RAM and 8 CPU cores):

```
incus-mig.sh Jim-Smith
```

Create a Debian 13 container using the default spec called Tim-Smith with a MIG GPU attached:

```
incus-mig.sh -d d13 -g Tim-Smith
```

Create a container called Dan-MacDonald with 128GB RAM, 16 CPU cores and the full NVIDIA GPU in the first PCI express slot passed through to the container:

```
incus-mig.sh -c 16 -m 128GB -G 01:00.0 Dan-MacDonald
```
