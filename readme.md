# Taskpony
> "A small and simple self-hosted personal tasks organiser"

## Table of contents

- [Features](#features)
- [Security](#security)
- [Installation](#installation)
  - [Docker](#docker)
  - [Docker Compose](#docker-compose)
  - [Linux service](#linux-service)
- [Documentation](#documentation)
- [Roadmap](#roadmap)
- [Schema](#schema)
- [Web paths](#web-paths)
- [Credits](#credits)
- [Licence](#licence)

# Features

Taskpony is intended to be small, easy to install and operate with a clean and intuitive interface. It wants to do one thing well - add, display and complete tasks. 

This means that there is a design choice to not add features that detract from this, such as Teams, Kanbans, integration with other software using caldav and so on. There are plenty of other good options that do offer these features, but I couldn't find something simple that did what I wanted. So I wrote this.

# Security 

Part of Taskpony's design choice is that there are no authentication systems built in. If you require authentication, such as a multi-user LAN or you are accessing Taskpony from the internet, you are strongly encouraged to use a reverse proxy with authentication in front of it. This could be [Nginx Proxy Manager](https://nginxproxymanager.com/), [Apache](https://httpd.apache.org/) configured to operate with a reverse proxy, or a cloud solution such as [Cloudflare](https://www.cloudflare.com) Tunnels protected by a suitable Access policy.

# Installation

Taskpony is intended to be easy to install and maintain. We document two ways to install it, using Docker or as a standalone Linux systemd service. 

## Docker

Install docker and run something like the following. 

`docker run -d -p 5000:5000 digdilem/taskpony:latest`

Within a few seconds, Taskpony should be available to your web browser on port 5000

If you want it to run on a different port, change the *first* 5000 to something else.

## Docker Compose

There is an example `docker-compose.yml` file in the archive. 

Copy this to your chosen directory and run: `docker compose up -d`

Taskpony should be available within a few seconds of that command completing on http://localhost:5000 

The default version mounts a persistant volume in `./data` where the Sqlite database `taskpony.db` will be created automatically.  Backing up this file will preserve all your tasks, lists and configuration. 

## Linux Service

Taskpony expects to be installed in `/opt/taskpony`

1. Make the directory and pull the files in from Github

EITHER: using git clone:

```
cd /opt
git clone https://github.com/digdilem/taskpony.git
```

OR, Download the zip from https://github.com/digdilem/taskpony and unpack into /opt/taskpony
```
cd /opt/
wget https://codeload.github.com/digdilem/taskpony/zip/refs/heads/main
unzip -a main
mv taskpony-main taskpony
```

2. Copy the supplied `taskpony.service` to `/etc/systemd/system` and start and enable it

```
cp /opt/taskpony/taskpony.service /etc/systemd/system
systemctl daemon-reload
systemctl enable --now taskpony
```

3. Visit port 5000 of that machine with your web browser. Eg, if it's localhost: `http://localhost:5000` and you should see Taskpony initial list.

Or if it's on a machine with an IP of 10.0.0.16, then `http://10.0.0.16:5000` - etc.

If you want to use another port instead of 5000, edit `taskpony.service` and change the plackup line. Eg: `ExecStart=/usr/bin/plackup -r -p 5001 /opt/taskpony/taskpony.psgi`

If you wish to run Taskpony in a directory other than `/opt/taskpony`, then change `$db_path` in `taskpony.psgi` and `WorkingDirectory` in `taskpony.service`

# Documentation

## Concepts: 
- Taskpony is a web based task system with a small footprint that is easy to install and uses very few resources. It should be usable on desktop and mobile devices without a dedicated app.
- It should be easy to self host and maintain. 
- Remain focused on a single user need and not spread into teamware. 
- Taskpony aspires  to follow the linux design tenet of "Do one thing well"

  
## The Name? 
 - This software was written on Dartmoor in England. There is a Dartmoor Pony grazing outside of my window as I write this. Dartmoor Ponies are compact, tough and hard working. Also, cute.

# Schema

Database schema: Taskpony uses Sqlite for simplicity and a small footprint.

/ TasksDb

    / TasksTb
        id
        Status (1 Active, 2 Deferred, 3 Completed)
        Title
        Description
        AddedDate = When created
        CompletedDate = When set as done. Is reset if task unset
        StartDate =  Tasks can be deferred    
        ListId = List this task belongs to
    
    / ListsTb  (List of Lists)
        id
        Title
        AddedDate
        DeletedDate
        Description
        Colour
        IsDefault
        
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
    
- /edit-list
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

Taskpony uses:

- [Perl 5](https://www.perl.org/)
- [Plack](https://plackperl.org/)
- [SQLite](https://sqlite.org/index.html)
- [Bootstrap 5](https://getbootstrap.com/)
- [Datatables](https://datatables.net/)

# Licence

Taskpony is released under the MIT Licence. 

You may use, copy, modify, and distribute your code for any purpose, as long as they include my original copyright notice and licence text.
