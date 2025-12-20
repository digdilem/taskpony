# Taskpony
> "A small and simple self-hosted personal tasks organiser"

![Main Task List](docs/tasks_short.jpg)

# Features

Taskpony is intended to be small, easy to install and operate with a clean and intuitive interface. It wants to do one thing well - add, display and complete tasks. 

Taskpony supports unlimited Tasks organised within unlimited Lists, repeating tasks and free movement of tasks within Lists. Tasks can be exported to the clipboard, CSV, PDF or cleanly printed.

No phone app required. The interface is responsive and scales well to all devices. There are no trackers and does not require access to the internet to function as all required files are included.

See some more [Screenshots](#screenshots)

**Quick start** - Deploy using [Docker Compose](#docker-compose) and visit port 5000. 

## Table of contents 

- [Features](#features)
- [Security](#security)
- [Installation](#installation)
  - [Requirements](#requirements)
  - [Docker](#docker)
  - [Docker Compose](#docker-compose)
  - [Linux service](#linux-service)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Upgrading](#upgrading)
- [Documentation](#documentation)
- [Roadmap](#roadmap)
- [Screenshots](#screenshots)
- [Schema](#schema)
- [Web paths](#web-paths)
- [Credits](#credits)
- [Licence](#licence)

# Security 

Part of Taskpony's design choice is that there are no authentication systems built in. If you require authentication, such as a multi-user LAN or you are accessing Taskpony from the internet, you are strongly encouraged to use a reverse proxy with authentication in front of it. This could be [Nginx Proxy Manager](https://nginxproxymanager.com/), [Apache](https://httpd.apache.org/) configured to operate with a reverse proxy, or a cloud solution such as [Cloudflare Tunnels](https://www.cloudflare.com) protected by an Access policy.

# Installation

Taskpony is intended to be easy to install and maintain. We document two ways to install it, using Docker or as a standalone Linux systemd service. 

# Requirements

Taskpony needs very little to run. 
* Disk space: The first release docker image is around 500Mb, but installing as systemd will need a lot less, around 200kb including the initial database. Obviously, more tasks = more disk space used by the database, but even so, it's KBs, not MBs unless you really have a lot to do!
* Memory: Around 30MB (systemd or docker)
* CPU: Almost any CPU will be fast enough.
* Clients: Browsers will typically use around 2-3MB of memory to load and display Taskpony.

## Limits

Taskpony has no artificial limits beyond those of the technologies, mostly SQLite. These are theoretically;

- Tasks and Lists - a maximum of 9.22 quintillian of each. 
- Text for each task or list's title or description can be up to a billion characters each. (Truncated in tables, but not everywhere. It's hoped users will be sane.)
- A total database size of 281 terabytes. (Subject to file system limits)

In reality, disk i/o performance is likely to be the limiting factor long before the above is reached.

## Docker

> The latest version of Taskpony is on [Dockerhub](https://hub.docker.com/repositories/digdilem) as `digdilem/taskpony:latest`

Install docker and run something like the following. 

`docker run -d -p 5000:5000 digdilem/taskpony:latest`

Within a few seconds, Taskpony should be available to your web browser on port 5000

If you want it to run on a different port, change the *first* 5000 to something else.

## Docker Compose

There is an example `docker-compose.yml` file in the repository which should work for most situations.

Copy this to your chosen directory, inspect and adjust as desired, and run: `docker compose up -d`

On completion, Taskpony should be available on http://localhost:5000 

The default version mounts a persistant volume in `./data` where the Sqlite database `taskpony.db` will be created automatically.

## Linux Service

Taskpony expects to be installed in `/opt/taskpony`. If you want it to exist elsewhere, you'll need to:

1. Edit `taskpony.psgi` and change `my $db_path = '/opt/taskpony/db/taskpony.db';` to point to the intended location of the database file that Taskpony will create.

2. Amend `taskpony.service` and change these lines to match your new path:

```
ExecStart=/usr/bin/plackup -r -p 5000 /opt/taskpony/taskpony.psgi
WorkingDirectory=/opt/taskpony
```

## Installing the program

1. Make the directory and pull the files in from Github

EITHER: using git clone:

```
cd /opt
apt-get install -y git
git clone https://github.com/digdilem/taskpony.git
```

OR, Download the zip from https://github.com/digdilem/taskpony and unpack into /opt/taskpony
```
cd /opt/
wget https://codeload.github.com/digdilem/taskpony/zip/refs/heads/main
unzip -a main
mv taskpony-main taskpony
```

2. Install the perl modules that taskpony requires

```
Debian 13
apt-get install libdbi-perl libdbd-sqlite3-perl libplack-perl perl
```

*For other distros, you'll need your distro packages for the following perl modules, or use cpanm/cpan to install them*

```
Plack::Request
Plack::Response
Plack::Builder
DBI
```

3. Copy the supplied `taskpony.service` to `/etc/systemd/system` and start and enable it

```
cp /opt/taskpony/taskpony.service /etc/systemd/system
systemctl daemon-reload
systemctl enable --now taskpony
```

4. Visit port 5000 of that machine with your web browser. Eg, if it's localhost: `http://localhost:5000` and you should see Taskpony initial list.

Or if it's on a machine with, say, an IP of 10.0.0.16, then `http://10.0.0.16:5000`

If you want to use another port instead of 5000, edit `taskpony.service` and change the plackup line. Eg: `ExecStart=/usr/bin/plackup -r -p 5001 /opt/taskpony/taskpony.psgi`

If you wish to run Taskpony in a directory other than `/opt/taskpony`, then change `$db_path` in `taskpony.psgi` and `WorkingDirectory` in `taskpony.service`

# Troubleshooting

If Taskpony doesn't work as expected, then:

## Docker

See output logs with `docker compose logs`

## Systemd

See output logs with `journalctl -u taskpony` or the current status with `systemctl status taskpony`

# FAQ

> Can I tell you about bugs or suggest improvements? 

Please do! The best place is to use [Github issues](https://github.com/digdilem/taskpony/issues) and raise a `New Issue`

> How do I back up my tasks?

All tasks, lists and settings are kept within the single file, `taskpony.db` stored in `/opt/taskpony/db` (Local if systemd, within `./data` if docker). This can be copied somewhere safe to back it up. If you need to restore a backup, just stop Taskpony, copy that file to where Taskpony expects it and restart Taskpony.

> Is there an Android or IOS app?

Sorry, no. Taskpony was designed to be a responsive web app and works well on both desktop and smaller devices, so an app is not considered necessary. (If you use a phone for your tasks as I do, create a shortcut on the desktop the Taskpony so it instantly opens in a browser)   If anyone wants to create an app for Taskpony, that's great, and if it's good then let me know and I'll reference it here.

> When will support for multiple users, groups or teams be added?

Never, sorry. This is a hard design choice to keep Taskpony small and simple and to avoid bloat. There are a lot of alternative projects with groupware ability if it is important to you.

> But I really want to run a copy for more than one person!

One way around this is to run multiple instances using docker, each with their own port.

> How do I add HTTPS? 

Use a reverse proxy - see [#security](#security)

> How do I protect my Taskpony with a username and password?

Use a reverse proxy - see [#security](#security)

> Does Taskpony support Caldav?

No. It may do in the future but there are no initial plans to do so.

> Can I use a different database type?

Not presently. SQLite was chosen to keep things small and simple. I think it should suffice for a task application.

# Upgrading

Upgrading Taskpony should be quite simple - overwrite the files and ensure taskpony.db survives. 

## Linux 

Follow the installation steps above and copy the new files over the existing ones. It's recommended that you back up the database first, but taskpony should automatically upgrade that if its needed. 

## Docker

Stop the existing container and repeat the installation instructions to pull the new image.

## Docker-Compose

Change to the directory you put your `docker-compose.yml`

Check the compose file with that of the new version and overwrite it if it's changed, then:

```
docker compose down
docker compose pull
docker compose up -d
```

# Documentation

Follow the [install guides](#installation) above, and you should be able to access Taskpony on http port 5000 with your web browser.

## About Tasks

The default page shows a pulldown menu at the top with an entry for the Default List (change this in the Lists page) followed by "All Lists" followed by an alpha-sorted list of the remaining Lists.

Below that is a quick entry form that allows you to add a task to the current list. Because it's autofocused, you can enter multiple tasks by typing, hitting enter, then typing the next one without needing to reselect it with the mouse. This form will be missing if "All lists" is selected. 

Then the main tasks lists is shown. Tick the checkbox to mark a task as *completed* which removes it from the *active* tasks. 

To reduce clutter, the dates and list name for tasks can be hidden in the main tasks list be disabling  `Show Dates and Lists in Tasks Table` in Settings.

A Filter or Search box is displayed top right if `Display Search Box` is selected in Settings that will only display matching strings.

Hover over the task Title to see a popup of the task's description if one was set. Tasks can be edited, and descriptions added to them, by clicking the title and completing the resulting form.

The tasks list can be sorted by clicking the header values.

If there are enough tasks to trigger the `Number of Tasks to show on each page` value in Settings, then the list will automatically paginate and show the number of pages together with Next/Previous buttons below it.

If `Display export buttons` is selected in Settings, then extra "Export" buttons appear under the list. These are:

![The Export Buttons](docs/buttons.jpg)

- `Copy` = Copy the contents of the List into the clipboard, allowing you to paste it elsewhere.
- `CSV` = Triggers a download of the chosen tasks as a CSV file allowing you to import them into a spreadsheet. 
- `PDF` = Generates a PDF of the tasks and downloads it.
- `Print` = Creates a clean, printable page and triggers the Print dialog, allowing you to make the tasklist physical. (Such as printing out a shopping list)

Below that is a final button to show completed tasks. This changes the view to show *completed* tasks instead of *active* ones. This allows you to "oops" and mark any completed tasks back as active. 

### Repeating Tasks

![Repeating Tasks](docs/repeating-task-list.jpg)

Tasks can be set to repeat a set number of days after completing. This is useful for tasks that need to be done every NN days - watering the plants, taking the bins out and so on. 

To enable this, create a task as normal and then click on it to Edit the task, then you can check these two fields to enable Repeat behaviour and set the number of days. 

![Repeating Task Settings](docs/repeating-form.jpg)

When this task is next checked as completed, it will disappear as normal. Once that number of days has passed, it will re-appear in the list as before.

To stop a task for repeating, you can either 

- Edit the Task, Untick the `Repeat this Task` box, or
- Edit the Task and click `Delete Task` to permanently remove it.

## About Lists

![Lists button](docs/lists-button.jpg)

The header shows a Lists button at the top right which takes you to `/lists` where you can manage Taskpony's Lists.

Here you can see all the Lists along with how many tasks, active or completed, within them.

You can edit any List by clicking on its title.

The `Default` button allows you to select a Default List. The Default List appears at the top of the Lists Picklist in the header.

If a Default List is deleted, Taskpony will automatically select the oldest active list and make that default to avoid being without one. 

When a List is chosen from the picklist, it will be automatically chosen on subsequent task list reloads until another is selected. 

## Database Backups

Each day, Taskpony will automatically make a backup of its database by copying `taskpony.db` to `taskpony.db.0`, and rename any previous backups incrementally (.1 to .2, .0 to .1 etc) You can configure how many backups to keep in Settings -> `Number of daily database backups to keep`. 

Restoring a database is a manual process:

1. Stop Taskpony. (Either `systemctl stop taskpony` or if Docker, change to the compose location and `docker compose down`)
2. Change to the directory containing taskpony.db (`cd /opt/taskpony/db` or if docker `cd data`)
3. Move the existing taskpony.db elsewhere (`mv taskpony.db taskpony.db.old`)
4. Copy the chosen backup to taskpony.db (`cp taskpony.db.3 taskpony.db`)
5. Restart Taskpony and it should now be using the restored database. 

Any issues during this process are likely to be file or permission related, and Taskpony should show them in its console. (`journalctl -u taskpony` or `docker compose logs`)

Because Taskpony's database is a simple sqlite3 file, it would be possible to automate this process allowing some interesting thoughts about resetting a demo instance or swapping datasets around for some purpose.

## Concepts
- Taskpony is a web based task system with a small footprint that is easy to install and uses very few resources. It should be usable on desktop and mobile devices without a dedicated app.
- It should be easy to self host and maintain. 
- Taskpony aspires  to follow the linux design tenet of "Do one thing well"
- Remain focused on a single user need and not spread into teamware. There are plenty of good foss alternatives that do offer team support, Kanbans, integration with other softare and so on. There are fewew good, single-user options like this. I couldn't find any that suited my own needs which led to me writing Taskpony.
  
## The Name? 
 - This software was written on Dartmoor in England. There is a Dartmoor Pony grazing outside of my window as I write this. Dartmoor Ponies are compact, tough and hard working. Also, cute.

# Screenshots

![Main Task List](docs/tasklist.jpg)

![Main Tasks List with dates and lists hidden](docs/tasklist_justtasks.jpg)

![List Management Page](docs/lists.jpg)

![Editing a Task](docs/edittask.jpg)

![Settings Page](docs/settings.jpg)

![Lists Pulldown](docs/lists_pulldown.jpg)

![Deleting a List](docs/delete_list.jpg)

![Statistics](docs/stats.jpg)

# Schema

Database schema: Taskpony uses Sqlite for simplicity and a small footprint. The schema is:

/ TasksDb

    / TasksTb    
        id
        Status (1 Active, 2 Completed)
        Title
        Description
        AddedDate = When created
        CompletedDate = When set as done. Is reset if task unset
        StartDate =  Tasks can be deferred    
        ListId = List this task belongs to
    Schema 2+:
        IsRecurring = on|off  Whether a task is set to repeat  
        RecurringIntervalDay = Number of days after a task is completed before it is set active
    
    / ListsTb  (List of Lists)
        id
        Title
        AddedDate
        DeletedDate = NULL if active, otherwise when deleted
        Description
        Colour = TBC
        IsDefault = The default list is sorted top of the picklist regardless of its alphaness.
        
    /ConfigTb  (Configuration)
        (Various key pairs of configuration values and persistent internal states. Many configurable on the /config page)
        id
        key
        value 
    
# Web Paths:

- /complete  
  - ?task_id=NN
    - Set TASK nn as Status 2 in TasksTb (Completed)
    - Return to main page

- /ust
  - ?task_id=NN
    - Set TASK nn as Status 1 in TasksTb (Active)
    - Return to main page
    
- /set_default_list
  - ?id=NN
    - Set all ListTb.IsDefault values to 0
    - Set ListTb.IsDefault value to 1 for NN
    - Return to main page
    
- /add 
  - Page 
    - Display page with form to add a new task. 
    - (Note, quick-add form also exists on main page for chosen list
  - POST
    - ?Title= (Req)
    - ?Description= (Opt)
    - ?ListId= (Opt)
        - Clean strings and insert new task into the specified or active List
        - Return to main page

- /edittask
  - Page
    - ?td=NN
    - Select task details for TasksTb.id = NN
    - Display edit form with them (Title, Description, ListId)
  - POST
    - ?id=NN
      - Fetch submitted form details for id, Title, Description and ListId
      - Sanitize details and update TasksTb for id = NN with them
      - Show main list
      
- /lists
  - Page
    - Display list of lists including active task counts, including an ALL Lists row. 
    - Append New List form
  - POST
    - ?list_id=NN
      - Receive form for new list submission
      - Sanitize strings and insert into ListsTb as a new entry
      - Show main lists page
    
- /editlist
  - Page
    - ?id=NN
      - Get information for list from ListsTb.id=NN
      - Display populated form for user to update details. 
  - POST
    - ?id=NN
      - Recieve form for editing an existing list. Sanitize input and update ListsTb.id with the submitted data
      - Show /lists page
      
- /config
  - Page
    - Display configuration editing form
        - task_pagination_length
        - description_short_length
        - list_short_length
        - include_datatable_buttons
  - POST
    - Receive form for config changes and update database.
        - POST values beginning with "cfg_"
    - Redirect to /
  
- /  (Default page)
  - ?delete_task=NN
    - Delete TasksTb.id=NN
    - Show / default page

  - /padd = Receive form to add a new project

  - /ust ?task_id=N = Unset a task from completed to active.    

# Credits

Taskpony is built with the help of this great FOSS software:

- [Perl 5](https://www.perl.org/)
- [Plack](https://plackperl.org/)
- [SQLite](https://sqlite.org/index.html) 
- [Bootstrap 5](https://getbootstrap.com/) (Bundled)
- [JQuery](https://jquery.com/) (Bundled)
- [Datatables](https://datatables.net/) (Bundled)
- [Fontawesome](https://fontawesome.com/) (Embedded SVGs)

# Roadmap

Some things for the future that may, or may not, be added. 

- (Probably) Configurable and automated deletion of tasks more than NN days since completion, or delete more than NN recent tasks.
- (Maybe) A priority system. Poss 3 dots on each task in list for one-touch change. Low, medium, high? Sorted accordingly?
- (Maybe) Add default sorting option, rather than just newest-first.
- (Maybe) Add colour to tasks lists. (Possibly based on priority, possibly a per-task setting)
- (Maybe) New release notification. 
- (Maybe) Multi-language support.
- (Maybe) A demo instance that resets every NN minutes?  (Perhaps a hardened docker that just deletes the database)  Free hosting required.
- (Maybe) Daily email report. Possibly showing outstanding tasks from Default list and summary stats.
- (Maybe) Some sort of toggleable daily progress badge "N tasks done today". Unsure of need/benefit.
- (Maybe) Ability to undelete Lists

# Version History

## 0.01 Initial release, 15th December 2025

## 0.2

"Improved orphan handing. Added repeating tasks, stats and database backups. Multiple bugfixes and UI improvements."

- Bugfix: Re-add html_escape() which had previously been merged with sanitize() and change calls to use it when displaying output. This corrects where tasks were stored and displayed with certain characters were made safe that didn't need to be. Quotes, single quotes, ampersands etc.
- UX: Renamed "All Lists" to "All Tasks" @halcyonloon https://github.com/digdilem/taskpony/issues/1
- UX: Removed blue link colour for dates in main list. (Link only there for tooltip on hover)
- UX: Orphaned tasks in "All Tasks" list now have a new in-line icon before the task title, and their List name changed to "[--No List--]" (if List and dates enabled)
- UX: List Management - when deleting a list, user is now presented with several options so they can decide what happens to any tasks within that list.
- UX: Clicking the task's List in the "All tasks" List now jumps to that List.
- UX: Top-right buttons: "Lists" changed to icon. Stats button added. All benefit from description popups. Slight change to div to wrap them onto second line for small devices as they were flowing off screen.
- UX: "N tasks completed today!" added to task completed banner
- Feature: Local stats calculated. Rate limited to 1/hr to avoid performance hit.
- Feature: /stats page added with some basic statistics.
- Change: Config save rewritten to make it easier to expand in the future.
- Feature: Daily backups of the database are now created. Number of them is configurable in /settings
- Feature: Recurring tasks added.
- Change: Daily functions call added for backups and repeating task management.


# Licence

Taskpony is released under the MIT Licence. 

You may use, copy, modify, and distribute your code for any purpose, as long as they include my original copyright notice and licence text.

\# End of file
