# overall

# 1 functions
## 1.1 ncclShmAllocateShareableBuffer
```cpp
ncclResult_t ncclShmAllocateShareableBuffer(size_t size, bool legacy, ncclShmIpcDesc_t *desc, void **hptr, void **dptr) {
	if (!legacy && support cuMem) {...}
	else {
		char shmPath[SHM_PATH_MAX] = { '\0' };
	    desc->shmli.shmSize = size;
	    NCCLCHECK(ncclShmOpen(shmPath, sizeof(shmPath), size, hptr, dptr, 1, &desc->shmli.handle));
	    memcpy(desc->shmli.shmSuffix, shmPath + sizeof("/dev/shm/nccl-") - 1, sizeof(desc->shmli.shmSuffix));
	    desc->legacy = true;
	    INFO(NCCL_SHM, "MMAP allocated shareable host buffer %s size %zi ptr %p", shmPath, desc->shmli.shmSize, *hptr);
	}
}
```
if 分支内：

else分支内：走ncclShmOpen的到一个 /dev/shm/nccl-xxxx 的共享映射，写到desc->shmli.shmSuffix内。


## 1.2 ncclShmImportShareableBuffer