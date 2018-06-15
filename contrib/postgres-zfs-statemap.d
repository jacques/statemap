#!/usr/sbin/dtrace -Cs 

/*
 * Copyright 2018, Joyent, Inc.
 */

#pragma D option quiet
#pragma D option destructive

#define T_WAKEABLE	0x0002

typedef enum {
	STATE_ON_CPU = 0,
	STATE_OFF_CPU_WAITING,
	STATE_OFF_CPU_SEMOP,
	STATE_OFF_CPU_BLOCKED,
	STATE_OFF_CPU_ZFS_READ,
	STATE_OFF_CPU_ZFS_WRITE,
	STATE_OFF_CPU_ZIL_COMMIT,
	STATE_OFF_CPU_TX_DELAY,
	STATE_OFF_CPU_DEAD,
	STATE_MAX
} state_t;

#define STATE_METADATA(_state, _str, _color) \
	printf("\t\t\"%s\": {\"value\": %d, \"color\": \"%s\" }%s\n", \
	    _str, _state, _color, _state < STATE_MAX - 1 ? "," : "");

BEGIN
{
	wall = walltimestamp;
	printf("{\n\t\"start\": [ %d, %d ],\n",
	    wall / 1000000000, wall % 1000000000);
	printf("\t\"title\": \"PostgreSQL statemap on %s, by process ID\",\n",
	    `utsname.nodename);
	printf("\t\"host\": \"%s\",\n", `utsname.nodename);
	printf("\t\"entityKind\": \"Process\",\n");
	printf("\t\"states\": {\n");

	STATE_METADATA(STATE_ON_CPU, "on-cpu", "#DAF7A6")
	STATE_METADATA(STATE_OFF_CPU_WAITING, "off-cpu-waiting", "#f9f9f9")
	STATE_METADATA(STATE_OFF_CPU_SEMOP, "off-cpu-semop", "#FF5733")
	STATE_METADATA(STATE_OFF_CPU_BLOCKED, "off-cpu-blocked", "#C70039")
	STATE_METADATA(STATE_OFF_CPU_ZFS_READ, "off-cpu-zfs-read", "#FFC300")
	STATE_METADATA(STATE_OFF_CPU_ZFS_WRITE, "off-cpu-zfs-write", "#338AFF")
	STATE_METADATA(STATE_OFF_CPU_ZIL_COMMIT,
	    "off-cpu-zil-commit", "#66FFCC")
	STATE_METADATA(STATE_OFF_CPU_TX_DELAY, "off-cpu-tx-delay", "#CCFF00")
	STATE_METADATA(STATE_OFF_CPU_DEAD, "off-cpu-dead", "#E0E0E0")

	printf("\t}\n}\n");
	start = timestamp;
}

sched:::wakeup
/execname == "postgres" && args[1]->pr_fname == "postgres"/
{
	printf("{ \"time\": \"%d\", \"entity\": \"%d\", ",
	    timestamp - start, pid);
	printf("\"event\": \"wakeup\", \"target\": \"%d\" }\n",
	    args[1]->pr_pid);
}

fbt::zfs_read:entry
/execname == "postgres"/
{
	self->state = STATE_OFF_CPU_ZFS_READ;
}

fbt::zfs_write:entry
/execname == "postgres"/
{
	self->state = STATE_OFF_CPU_ZFS_WRITE;
}

syscall:::return
/execname == "postgres"/
{
	self->state = STATE_ON_CPU;
}

fbt::semop:entry
/execname == "postgres"/
{
	self->state = STATE_OFF_CPU_SEMOP;
}

fbt::semop:return
/execname == "postgres"/
{
	self->state = STATE_ON_CPU;
}

fbt::zil_commit:entry
/self->state == STATE_OFF_CPU_ZFS_WRITE/
{
	self->state = STATE_OFF_CPU_ZIL_COMMIT;
}

fbt::zil_commit:return
/self->state == STATE_OFF_CPU_ZIL_COMMIT/
{
	self->state = STATE_OFF_CPU_ZFS_WRITE;
}

fbt::dmu_tx_delay:entry
/self->state == STATE_OFF_CPU_ZFS_WRITE/
{
	self->state = STATE_OFF_CPU_TX_DELAY;
}

fbt::dmu_tx_delay:return
/self->state == STATE_OFF_CPU_TX_DELAY/
{
	self->state = STATE_OFF_CPU_ZFS_WRITE;
}

sched:::off-cpu
/execname == "postgres"/
{
	printf("{ \"time\": \"%d\", \"entity\": \"%d\", ",
	    timestamp - start, pid);

	printf("\"state\": %d }\n", self->state != STATE_ON_CPU ?
	    self->state : (curthread->t_flag & T_WAKEABLE ?
	    STATE_OFF_CPU_WAITING : STATE_OFF_CPU_BLOCKED));
}

sched:::on-cpu
/execname == "postgres"/
{
	printf("{ \"time\": \"%d\", \"entity\": \"%d\", ",
	    timestamp - start, pid);
	printf("\"state\": %d }\n", STATE_ON_CPU);
}

proc:::exit
/execname == "postgres"/
{
	self->exiting = pid;
}

sched:::off-cpu
/execname != "postgres" && self->exiting/
{
	printf("{ \"time\": \"%d\", \"entity\": \"%d\", ",
	    timestamp - start, self->exiting);

	printf("\"state\": %d }\n", STATE_OFF_CPU_DEAD);
	self->exiting = 0;
	self->state = 0;
}

/*
 * This is -- to put it mildly -- very specific to the implementation of
 * PostgreSQL: if the process is long-running, it lifts argv[0] out of the
 * address space, and -- iff it matches the form "postgres: [description]
 * process", sets the description for the process to be [description].
 */
sched:::on-cpu
/execname == "postgres" &&
    timestamp - curthread->t_procp->p_mstart > 1000000000 &&
    !seen[pid]/
{
	seen[pid] = 1;
	this->arg = *(uintptr_t *)copyin(curthread->t_procp->p_user.u_argv, 8);
	this->index = index(this->process = copyinstr(this->arg), " process");

	if (this->index > 0 && index(this->process, "postgres: ") == 0) {
		printf("{ \"entity\": \"%d\", \"description\": \"%s\" }\n",
		    pid, substr(this->process, 10, this->index - 10));
	}
}

tick-1sec
/timestamp - start > 120 * 1000000000/
{
	exit(0);
}
