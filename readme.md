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

!! TODO

## Docker Compose

!! TODO

## Linux Service

Taskpony expects to be installed in `/opt/taskpony`

1. Make the directory and 

!!! TODO











# Notes and jottings



Why: I spent a long time trying various self hosted task apps in my search to replace Google Tasks. There are a lot, but I could not find one that suited my specific need, so I wrote this. 

Concepts: 
A web task system with a small footprint that is easy to install and uses very few resources. It should be usable on mobile devices.

Roadmap:
Some fairly opinionated decisions here. 

   Task Pony will: 
    - Remember that it's a simple tasks application.
    - Be small and fast.
    - Be easy to self-host, either natively or in Docker.
    - Remain focused on a single user need. That means no teams, groups or individual user preferences or logins. 
    - Automatically upgrade schema when required.
    
    Taskpony may, in future versions:
    - Add recurring tasks
    - Include bootstrap and datatables locally instead of CDN
    - Support webhooks
    - Add theming, background images etc.
    - Support searching.
    - Support notifications or daily task list announcements.
    - Be able to export and import tasks.

    Taskpony will not:
    - Support multiple users, teams. There are plenty of good options if you want this.
    - Include any features not directly related to tasks or lists of tasks.
    - Dedicated optional fields like Location, People etc which can be put in Description.
    - Include kanbans. 
    - Complicated workflow; single click actions are preferred.
    - Support https or an auth system. (Use a reverse proxy like NPM, Apache or Cloudflare for security. Don't connect this directly to the internet.)
    - Use external databases for simplicity. (First version did use MariaDb but was redrafted for SQLite to keep it small and simple)
  
The Name? 
    This software was written on Dartmoor in England. There is a Dartmoor Pony grazing outside of my window as I write this. They are compact, tough and hard working. Also, cute.




Database schema: Sqlite for simplicity and small footprint. 

/ TasksTb

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
        id
        key
        value
        
        Values:
            active_project  = list_id
            database_schema_version = 
            + Contents of $config hashref, prefixed cfg_
                
            
    
    
    
### Web Paths:

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
    


/padd = Form to add a new project

/ust ?task_id=N




# Credits

Taskpony uses:

- Perl 5
- Plack
- SQLite
- [Bootstrap 5](https://getbootstrap.com/)
- [Datatables](https://datatables.net/)

# Licence

Taskpony is released under the MIT Licence. 

You may use, copy, modify, and distribute your code for any purpose, as long as they include my original copyright notice and licence text.