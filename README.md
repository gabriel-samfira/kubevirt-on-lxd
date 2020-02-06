# Set up Kubevirt on LXD

This is a quick and dirty script to set up a [kubevirt](https://github.com/kubevirt/kubevirt) deployment on LXD managed virtual machines. The deployment should be used strictly for feature testing and for development purposes. It goes without saying that performance will not be great, considering it is a nested virtualization environment. This script deploys 3 nodes:

  * k8s-master
  * k8s-node01
  * k8s-iscsi

## Prerequisites

This script requires LXD version ```3.20``` or above.

## You should know

This script will create 8 new profiles that will be used to create virtual machines. Most of them are in the profiles folder of this repository. One aditional ```vm_base``` profile will be created, that will contain a ```userdata``` script needed to set up the ```lxd``` agent and inject the SSH public key.

I recommend you inspect the profiles in the ```profiles``` folder and assign resources that are more in sync with the hardware at your disposal. Make sure you tweak the disk space allocated to each profile.

## Deploy

Simply run:

```bash
./deploy.sh --github-user YOUR_GITHUB_USERNAME
```

The github username is used to fetch your public key from github and inject in the VMs that get spun up. Make sure you have at least one valid public key added to your github account.

Other options:

```bash
./deploy.sh flags
    
--github-user   The github username from which we fetch the public key
--lxd-br-name   LXD bridge name to use for VMs. Defaults to lxdbr0.
--admin-user    The admin user with full sudo access. Defaults to ubuntu.
--clobber       Use this option to overwrite any existing settings with those in this script.
```

Good luck!
