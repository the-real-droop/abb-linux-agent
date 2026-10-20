// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal ioctl client for disposable-VM integration tests.
 * Build: cc -O2 -Wall -Wextra -Werror -static -o snapshot-smoke snapshot-smoke.c
 * These commands create/destroy snapshots and COW files. Use a test disk.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "../patches/synosnap/elastio-snap.h"

static void usage(const char *program)
{
	fprintf(stderr,
		"Usage: %s setup MINOR BDEV COW [COW_MIB]\n"
		"       %s info MINOR\n"
		"       %s inc MINOR\n"
		"       %s snap MINOR COW [COW_MIB]\n"
		"       %s destroy MINOR\n"
		"       %s free\n"
		"Control device: SYNOSNAP_CONTROL or /dev/synosnap-ctl\n",
		program, program, program, program, program, program);
}

static unsigned long number(const char *value, unsigned long maximum)
{
	char *end;
	unsigned long result;

	errno = 0;
	result = strtoul(value, &end, 10);
	if (errno || *value == '\0' || *value == '-' || *end || result > maximum) {
		fprintf(stderr, "Invalid number: %s\n", value);
		exit(2);
	}
	return result;
}

int main(int argc, char **argv)
{
	const char *control = getenv("SYNOSNAP_CONTROL");
	unsigned int minor = 0;
	int fd, result = -1;

	if (argc < 2) {
		usage(argv[0]);
		return 2;
	}
	if (strcmp(argv[1], "free") != 0) {
		if (argc < 3) {
			usage(argv[0]);
			return 2;
		}
		/* The module supports at most 255 devices: minor 0 through 254. */
		minor = (unsigned int)number(argv[2], 254);
	}

	if (!control)
		control = "/dev/synosnap-ctl";
	fd = open(control, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror(control);
		return 1;
	}

	if (strcmp(argv[1], "setup") == 0 && (argc == 5 || argc == 6)) {
		struct setup_params params = {
			.bdev = argv[3],
			.cow = argv[4],
			.fallocated_space = argc == 6 ? number(argv[5], ULONG_MAX / (1024 * 1024)) : 16,
			.cache_size = 4 * 1024 * 1024,
			.minor = minor,
			.ignore_snap_errors = false,
		};
		result = ioctl(fd, IOCTL_SETUP_SNAP, &params);
	} else if (strcmp(argv[1], "info") == 0 && argc == 3) {
		struct elastio_snap_info info = { .minor = minor };
		result = ioctl(fd, IOCTL_ELASTIO_SNAP_INFO, &info);
		if (result == 0) {
			printf("minor=%u state=%lu error=%d cancelled=%u seqid=%llu "
			       "changed_blocks=%llu cow=%s bdev=%s\n",
			       info.minor, info.state, info.error, info.is_cancelled,
			       info.seqid, info.nr_changed_blocks, info.cow, info.bdev);
			if (info.error || info.is_cancelled) {
				close(fd);
				return 1;
			}
		}
	} else if (strcmp(argv[1], "inc") == 0 && argc == 3) {
		result = ioctl(fd, IOCTL_TRANSITION_INC, &minor);
	} else if (strcmp(argv[1], "snap") == 0 && (argc == 4 || argc == 5)) {
		/* The implementation interprets this field as MiB for both commands. */
		struct transition_snap_params params = {
			.cow = argv[3],
			.fallocated_space = argc == 5 ? number(argv[4], ULONG_MAX / (1024 * 1024)) : 16,
			.minor = minor,
		};
		result = ioctl(fd, IOCTL_TRANSITION_SNAP, &params);
	} else if (strcmp(argv[1], "destroy") == 0 && argc == 3) {
		result = ioctl(fd, IOCTL_DESTROY, &minor);
	} else if (strcmp(argv[1], "free") == 0 && argc == 2) {
		int available = -1;
		result = ioctl(fd, IOCTL_GET_FREE, &available);
		if (result == 0)
			printf("free_minor=%d\n", available);
	} else {
		usage(argv[0]);
		close(fd);
		return 2;
	}

	if (result < 0) {
		fprintf(stderr, "%s: %s\n", argv[1], strerror(errno));
		close(fd);
		return 1;
	}
	printf("%s: OK\n", argv[1]);
	close(fd);
	return 0;
}
