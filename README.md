# incus-mig

**incus-mig** automates the creation of Debian and Ubuntu [incus containers](https://linuxcontainers.org/incus/) and virtual machines, focusing on making it easy to attach a [NVIDIA MIG](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html) or a full NVIDIA PCI express GPU although doing any of that is optional. It can be otherwise used as a quick and easy way to create Debian and Ubuntu incus instances.

This script requires root access and has to be run on an incus server that has been configured to use an incus managed network bridge interface, created and managed by incus.

You must have the CUDA toolkit installed on the incus server and you need to have configured at least one MIG device (using [mig-parted](https://github.com/NVIDIA/mig-parted)) before running the script if you wish to use the -g or -m option to attach a MIG GPU. The incus-mig -g and -m (MIG GPU attach) options only work with containers. incus and incus-mig do not support attaching MIG GPUs to virtual machines.

You should be able to use -G without any MIG to do PCIe passthrough of a full GPU to an incus container or VM.

**incus-mig.sh** also configures incus snapshots (one every 12 hours), installs **openssh-server** and configures a password for the root user. It is recommended you use a ZFS based incus storage pool so that incus can take advantage of native ZFS snapshots.

**incus-cleanup.sh** should be configured to be run via a daily root cron job to disable and delete old containers.

The following root cron job could be used to run the incus-cleanup.sh script at 2 AM every day, if it was copied into /usr/local/bin.

```
0 2 * * * /usr/local/bin/incus-cleanup.sh
```

New containers and VMs created with incus-mig are given an expiry date two months from the day of creation by default. To skip adding an expiry date use the -x flag.

**gpu-stats.py** can be run via cron to log NVIDIA GPU activity via **nvitop**. See below for more details.

Do not use dots or any other punctuation for container names.

## incus-mig container creation example commands

Before running any of the following incus-mig commands, check and adjust the default values at the top of the script and adjust them to values suitable for new incus units being created on your incus server. Most of them can be set on the command line. Run **incus-mig.sh** without any options to see all of the command line options that **incus-mig.sh** has.

Create a Ubuntu (24.04) incus container called **Jim-Smith** with no GPU attached using the default spec defined within the script (900GB HD, 32GB RAM and 8 CPU cores):

```
incus-mig.sh Jim-Smith
```

Create a Debian 13 container using the default spec called **Tim-Smith** with a randomly selected MIG GPU attached:

```
incus-mig.sh -d d13 -g Tim-Smith
```

Create a container called **Dan-MacDonald** with 128GB RAM, 16 CPU cores with the full NVIDIA GPU in the first PCI express slot passed through to the container:

```
incus-mig.sh -c 16 -r 128GB -G 01:00.0 Dan-MacDonald
```

Create a VM with no expiry date:
```
incus-mig.sh -v -x Mr-Trismegistus
```

## Key incus-mig server admin commands

List all configured MIG GPUs whether attached to an incus container or not:

```
nvidia-smi -L
```

List all incus containers, VMs and any attached MIG GPU ids, if configured:

```
incus list -f compact -c n,devices:gpu0.mig.uuid
```

Get expiry date of container/VM named Tim-Smith:

```
incus config get Tim-Smith user.expiry
```

Change expiry date of Tim's container:

```
incus config set Tim-Smith user.expiry 2020-06-21
```

To change Dan's CPU limit to 32 CPU cores:

```
incus config set Dan-MacDonald limits.cpu 32
```

To change Jim's RAM limit to 64GB:

```
incus config set Jim-Smith limits.memory 64GB
```

## Using the -n (NO_GPU_DETACH) option

This script presumes that all of your free MIG GPUs have the same configuration so it attaches any unused MIG GPU to the new container when you use the -g option. Therefore, if you have have some MIG GPUs using a different MIG profile to the bulk of your MIG GPUs, you should assign those different spec GPUs to containers using the -m option so that this script doesn't attempt to assign the different spec MIG GPUs to new containers when you use -g to randomly assign a MIG GPU from the ones currently available.

When you are creating a container that will use a MIG GPU that you don't want to be auto-assigned by the incus-mig script using -m , you should also use -n (NO_GPU_DETACH). Using -n will set the containers NO_GPU_DETACH option to true and will prevent the cleanup script from detaching the GPU from the container when it gets disabled on its expiry date, preventing it being added into the pool of available GPUs.

The cleanup script will detach GPUs from containers on their expiry date so that they may be used by new containers but it does not automatically delete containers that have NO_GPU_DETACH set to true.

If you DIDN'T use the -n option when creating Jim's container, you could run:

```
incus config set Jim-Smith user.nogpudetach true
```

To check the nogpudetach config option:

```
incus config get Jim-Smith user.nogpudetach
```

This is the end of the incus-mig section of the README. What follows are notes on the other scripts in this repo.

## gpu-stats.py

gpu-stats.py can be run to generate NVIDIA GPU stat log files using nvitop for all active MIG and non-MIG enabled GPUs.

* Create the virtual environment:
```
python3 -m venv /root/gpu-env
```

* Install nvitop specifically into that environment:
```
/root/gpu-env/bin/pip install nvitop
```
* Run your script using the environment's python:
```
/root/gpu-env/bin/python3 /root/gpu-env/bin/gpu-stats.py
```

Adjust that last path to point to wherever you copied **gpu-stats.py**
 
## incus logging
 
The incus documentation [recommends setting up a Prometheus server](https://linuxcontainers.org/incus/docs/main/metrics/) for monitoring incus metrics but if you don't need to capture every incus metric or you don't have the resources to run a Prometheus server you could instead create a root cron job like this:
 
```
* * * * * /usr/bin/incus list status=running -f csv -c n4Dmu,devices:gpu0.mig.uuid,devices:gpu0.pci | /usr/bin/awk -v ts="$(date '+%Y-%m-%d %H:%M:%S')" '{ print ts "," $0 }' >> /var/log/incus/incus-stats.log
```

This will log the memory, CPU, used disk space and IP address of all running incus containers. It will also log either the MIG UUID or PCI ID if a gpu is attached to a container as device ID gpu0.

## incus-info.sh

incus-info.sh can be used to generate a simple web page dashboard that displays the names of all active incus containers and their expiry dates.
