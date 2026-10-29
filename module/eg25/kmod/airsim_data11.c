// SPDX-License-Identifier: GPL-2.0-only
/* QDC507 DATA11 application AT channel. The USB owner must be unbound first. */
#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <soc/qcom/smd.h>

struct data11_session {
	smd_channel_t *channel;
	wait_queue_head_t wait;
	bool connected;
};

static atomic_t opened = ATOMIC_INIT(0);

static void data11_event(void *arg, unsigned event)
{
	struct data11_session *s = arg;
	if (event == SMD_EVENT_OPEN)
		WRITE_ONCE(s->connected, true);
	else if (event == SMD_EVENT_CLOSE)
		WRITE_ONCE(s->connected, false);
	wake_up_interruptible(&s->wait);
}

static int data11_open(struct inode *inode, struct file *file)
{
	struct data11_session *s;
	int rc;
	if (atomic_cmpxchg(&opened, 0, 1))
		return -EBUSY;
	s = kzalloc(sizeof(*s), GFP_KERNEL);
	if (!s) {
		rc = -ENOMEM;
		goto unlock;
	}
	init_waitqueue_head(&s->wait);
	rc = smd_named_open_on_edge("DATA11", SMD_APPS_MODEM,
			&s->channel, s, data11_event);
	if (rc)
		goto free;
	rc = wait_event_interruptible_timeout(s->wait,
			READ_ONCE(s->connected), msecs_to_jiffies(2000));
	if (rc <= 0) {
		if (!rc)
			rc = -ETIMEDOUT;
		smd_close(s->channel);
		goto free;
	}
	file->private_data = s;
	return nonseekable_open(inode, file);
free:
	kfree(s);
unlock:
	atomic_set(&opened, 0);
	return rc;
}

static int data11_release(struct inode *inode, struct file *file)
{
	struct data11_session *s = file->private_data;
	smd_close(s->channel);
	kfree(s);
	atomic_set(&opened, 0);
	return 0;
}

static ssize_t data11_read(struct file *file, char __user *buf,
			  size_t count, loff_t *pos)
{
	struct data11_session *s = file->private_data;
	char *data;
	int rc;
	if (!count)
		return 0;
	while (!smd_read_avail(s->channel)) {
		if (!READ_ONCE(s->connected))
			return -EIO;
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		rc = wait_event_interruptible(s->wait,
			!READ_ONCE(s->connected) || smd_read_avail(s->channel));
		if (rc)
			return rc;
	}
	count = min_t(size_t, count, 4096);
	data = kmalloc(count, GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	rc = smd_read(s->channel, data, count);
	if (rc > 0 && copy_to_user(buf, data, rc))
		rc = -EFAULT;
	kfree(data);
	return rc;
}

static ssize_t data11_write(struct file *file, const char __user *buf,
			   size_t count, loff_t *pos)
{
	struct data11_session *s = file->private_data;
	char *data;
	int rc;
	if (!count)
		return 0;
	if (!READ_ONCE(s->connected))
		return -EIO;
	count = min_t(size_t, count, 4096);
	data = memdup_user(buf, count);
	if (IS_ERR(data))
		return PTR_ERR(data);
	rc = smd_write(s->channel, data, count);
	kfree(data);
	return rc ? rc : -EAGAIN;
}

static unsigned int data11_poll(struct file *file, poll_table *wait)
{
	struct data11_session *s = file->private_data;
	unsigned int mask = 0;
	poll_wait(file, &s->wait, wait);
	if (!READ_ONCE(s->connected))
		return POLLERR | POLLHUP;
	if (smd_read_avail(s->channel))
		mask |= POLLIN | POLLRDNORM;
	if (smd_write_avail(s->channel))
		mask |= POLLOUT | POLLWRNORM;
	return mask;
}

static const struct file_operations data11_ops = {
	.owner = THIS_MODULE,
	.open = data11_open,
	.release = data11_release,
	.read = data11_read,
	.write = data11_write,
	.poll = data11_poll,
	.llseek = no_llseek,
};

static struct miscdevice data11_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "airsim_data11",
	.fops = &data11_ops,
	.mode = 0600,
};

static int __init data11_init(void)
{
	return misc_register(&data11_device);
}

static void __exit data11_exit(void)
{
	misc_deregister(&data11_device);
}

module_init(data11_init);
module_exit(data11_exit);
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("AirSIM QDC507 DATA11 AT transport");
