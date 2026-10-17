#!/bin/bash
SCRIPT_DIR=`dirname $( readlink -m $( type -p $0 ))`

# Ensure your SSH private key has been added to the ssh-agent as follows:
# ssh-add /home/$USER/.ssh/id_rsa

# Example Usage:
# ./run.sh make build

COMMAND=(bash)
INTERACTIVE='-it'
if [ -n "$1" ]
then
  # keep the arguments as an array, so that quoted arguments with spaces survive
  COMMAND=("$@")
  INTERACTIVE=''
fi

docker run \
  -w /home/`whoami`/rosindex \
  -v $SCRIPT_DIR/..:/home/`whoami`/rosindex:rw \
  -e GITHUB_TOKEN \
  --net=host $INTERACTIVE rosindex/rosindex "${COMMAND[@]}"
