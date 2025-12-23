# Some technical information about Taskpony removed from the main README.md for brevity


# Requirements

Taskpony needs very little to run. 

- Disk space: Between 200kb (systemd version) or around 500mb (Docker image)  Obviously, more tasks = more disk space used by the database, but even so, that's KBs, not MBs unless you *really* have a lot to do!
- Memory: Around 30MB (systemd or docker)
- CPU: Almost any CPU will be fast enough.
- Clients: Browsers will typically use around 2-3MB of memory to load and display Taskpony.


# Limits

Taskpony has no artificial limits beyond those of the technologies, mostly SQLite. These are theoretically;

- Tasks and Lists - a maximum of 9.22 quintillian of each. 
- Text for each task or list's title or description can be up to a billion characters each. (Truncated in tables, but not everywhere. It's hoped users will be sane.)
- A total database size of 281 terabytes. (Subject to file system limits)

In reality, disk i/o performance is likely to be the limiting factor long before the above is reached.

