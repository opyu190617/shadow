#include <stdio.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "../ShadowEngine/Shadow.h"

int mount_apfs_snapshot(char *snapshot, char *volume, char *directory) {
    // Check if already mounted.
    if([[NSFileManager defaultManager] fileExistsAtPath:@"/var/MobileSoftwareUpdate/mnt1/.file"]) {
        return 0;
    }

    pid_t pid;
    char *argv[] = {"mount_apfs", "-s", snapshot, volume, directory, NULL};
    int ret;

    if(posix_spawn(&pid, "/sbin/mount_apfs", NULL, NULL, argv, NULL) == 0) {
        waitpid(pid, &ret, WEXITED);
        return ret;
    }

    return -1;
}

int main(int argc, char *argv[], char *envp[]) {
    if(getuid() != 0) {
        // Attempt to setuid.
        setuid(0);
        setuid(0);

        if(getuid() != 0) {
            // Failed.
            printf("error: failed to get root privileges.\n");
            return -1;
        }
    }

    if(![[NSFileManager defaultManager] fileExistsAtPath:@"/Library/Shadow"]) {
        if(mkdir("/Library/Shadow", S_IRUSR|S_IWUSR|S_IRGRP|S_IROTH) == -1) {
            printf("error: failed to create data directory.\n");
            return -1;
        }
    }

    // Mount orig-fs.
    if(mount_apfs_snapshot("orig-fs", "/", "/var/MobileSoftwareUpdate/mnt1") != 0) {
        printf("error: failed to mount orig-fs.\n");
        return -1;
    }

    NSURL *shadowdata_url = [NSURL fileURLWithPath:@"/Library/Shadow/shadowdata.plist"];
    NSMutableDictionary *shadowdata = [NSMutableDictionary dictionaryWithContentsOfURL:shadowdata_url];

    if(!shadowdata) {
        shadowdata = [NSMutableDictionary new];
    }

    // Generate orig-fs file map if it doesn't exist.
    if(!shadowdata[@"orig-fs"]) {
        // Enumerate snapshot files and compile into a plist.
        NSMutableDictionary *origfs_plist = [NSMutableDictionary new];
        NSDirectoryEnumerator *origfs_enum = [[NSFileManager defaultManager] enumeratorAtPath:@"/var/MobileSoftwareUpdate/mnt1"];

        NSString *file;
        BOOL isDir;

        while((file = [origfs_enum nextObject])) {
            NSString *file_abs = [NSString stringWithFormat:@"/var/MobileSoftwareUpdate/mnt1/%@", file];
            NSString *file_abs_orig = [NSString stringWithFormat:@"/%@", file];

            if([[NSFileManager defaultManager] fileExistsAtPath:file_abs isDirectory:&isDir]) {
                origfs_plist[file_abs_orig] = @(isDir);
            }
        }

        // Write to Shadow data.
        shadowdata[@"orig-fs"] = origfs_plist;
    }

    // Generate dpkg file map.
    NSMutableSet *dpkg_plist = [NSMutableSet new];
    NSMutableSet *urlscheme_plist = [NSMutableSet new];
    NSString *dpkg_path = @"/var/lib/dpkg/info";
    NSArray *dpkg_enum = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dpkg_path error:nil];

    if(dpkg_enum) {
        for(NSString *file in dpkg_enum) {
            if([[file pathExtension] isEqualToString:@"list"]) {
                // Skip some packages.
                if([file isEqualToString:@"firmware-sbin.list"]
                || [file hasPrefix:@"gsc."]
                || [file hasPrefix:@"cy+"]) {
                    continue;
                }

                NSString *file_abs = [dpkg_path stringByAppendingPathComponent:file];
                NSString *file_contents = [NSString stringWithContentsOfFile:file_abs encoding:NSUTF8StringEncoding error:NULL];

                if(file_contents) {
                    NSArray *dpkg_files = [file_contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

                    for(NSString *dpkg_file in dpkg_files) {
                        if([dpkg_file hasPrefix:@"/Applications"] && [[dpkg_file pathExtension] isEqualToString:@"app"]) {
                            BOOL isDir;

                            if([[NSFileManager defaultManager] fileExistsAtPath:dpkg_file isDirectory:&isDir] && isDir) {
                                // Open Info.plist
                                NSURL *plist_info_url = [NSURL fileURLWithPath:[dpkg_file stringByAppendingPathComponent:@"Info.plist"]];
                                NSMutableDictionary *plist_info = [NSMutableDictionary dictionaryWithContentsOfURL:plist_info_url];

                                if(plist_info) {
                                    for(NSDictionary *type in plist_info[@"CFBundleURLTypes"]) {
                                        for(NSString *scheme in type[@"CFBundleURLSchemes"]) {
                                            [urlscheme_plist addObject:scheme];
                                        }
                                    }
                                }
                            }

                            continue;
                        }

                        BOOL isDir;

                        if([[NSFileManager defaultManager] fileExistsAtPath:dpkg_file isDirectory:&isDir] && !isDir) {
                            [dpkg_plist addObject:dpkg_file];
                        }
                    }
                }
            }
        }
    }

    // Write to Shadow data.
    shadowdata[@"dpkg"] = [dpkg_plist allObjects];
    shadowdata[@"url_schemes"] = [urlscheme_plist allObjects];

    if(![shadowdata writeToURL:shadowdata_url error:nil]) {
        return -1;
    }

    return 0;
}
