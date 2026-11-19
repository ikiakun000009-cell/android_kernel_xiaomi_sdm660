#include <linux/fs.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/string.h>

static void replace_cmdline_flag(char *buf, const char *key, const char *val)
{
	char *p = strstr(buf, key);
	size_t klen = strlen(key);
	size_t vlen = strlen(val);

	if (!p)
		return;
	p += klen;
	while (*p && *p != ' ' && vlen > 0) {
		*p++ = *val++;
		vlen--;
	}
	while (*p && *p != ' ')
		*p++ = ' ';
}

static int cmdline_proc_show(struct seq_file *m, void *v)
{
	char *clean_cmd = kstrdup(saved_command_line, GFP_KERNEL);

	if (!clean_cmd) {
		seq_printf(m, "%s\n", saved_command_line);
		return 0;
	}

	replace_cmdline_flag(clean_cmd, "androidboot.verifiedbootstate=", "green ");
	replace_cmdline_flag(clean_cmd, "androidboot.flash.locked=", "1");
	replace_cmdline_flag(clean_cmd, "androidboot.vbmeta.device_state=", "locked  ");

	seq_printf(m, "%s\n", clean_cmd);
	kfree(clean_cmd);
	return 0;
}

static int cmdline_proc_open(struct inode *inode, struct file *file)
{
	return single_open(file, cmdline_proc_show, NULL);
}

static const struct file_operations cmdline_proc_fops = {
	.open		= cmdline_proc_open,
	.read		= seq_read,
	.llseek		= seq_lseek,
	.release	= single_release,
};

static int __init proc_cmdline_init(void)
{
	proc_create("cmdline", 0, NULL, &cmdline_proc_fops);
	return 0;
}
fs_initcall(proc_cmdline_init);
