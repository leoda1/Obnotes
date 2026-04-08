```shell title="抓 nsys"
if [ $OMPI_COMM_WORLD_RANK -eq 0 ]; then
  nsys profile --force-overwrite true -t cuda,nvtx,osrt -o nccl_ce${OMPI_COMM_WORLD_RANK} -e NSYS_MPI_STORE_TEAMS_PER_RANK=1 "$@"
else
  "$@"
fi
```