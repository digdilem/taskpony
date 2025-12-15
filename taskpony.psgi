#!/usr/bin/env/perl
# Taskpony - a simple perl PSGI web app for various daily tasks
# Single user, sqlite backend, bootstrap front end
# Started Christmas, 2025. Simon Avery / digdilem / https://digdilem.org
# MIT Licence

use strict;
use warnings;

use Plack::Request;         # Perl PSGI web framework
use Plack::Response;        # Ditto
use DBI;                    # Database interface for SQLite
use Time::Local;            # For human friendly date function

use Plack::Builder;         # Favicon
use File::Spec::Functions qw(catdir);
use FindBin;

###############################################
# Default configuration, overriden by ConfigTb values, change them via settings page
our $config = {
    cfg_task_pagination_length => 25,           # Number of tasks to show per page 
    cfg_description_short_length => 30,         # Number of characters to show in task list before truncating description (Cosmetic only)
    cfg_list_short_length => 20,                # Number of characters to show in list column in task display before truncating (Cosmetic only)
    cfg_include_datatable_buttons => 'on',      # Include the CSV/Copy/PDF etc buttons at the bottom of each table
    cfg_include_datatable_search => 'on',       # Include the search box at the top right of each table
    cfg_export_all_cols => 'off',               # Export all columns in datatable exports, not just visible ones
    cfg_header_colour => 'secondary',           # Bootstrap 5 colour of pane backgrounds
    };

###############################################
# Global variables that are used throughout - do not change these. They will not persist during app updates.
my $app_title = 'Taskpony';             # Name of app.
my $app_version = '0.01';               # Version of app
my $database_schema_version = 1;        # Current database schema version. Do not change this, it will be modified during updates.
my $db_path = '/opt/taskpony/db/taskpony.db';    # Path to Sqlite database file internal to docker. If not present, it will be auto created. 

my $dbh;                        # Global database handle 
my $list_id = 1;                # Current list id
my $list_name;                  # Current list name
my $debug = 0;                  # Set to 1 to enable debug messages to STDERR
my $alert_text = '';            # If set, show this alert text on page load
my $show_completed = 0;         # If set to 1, show completed tasks instead of active ones

# Some inline SVG fontawesome icons to prevent including the entire svg map
my $fa_header = q~<svg class="icon" aria-hidden="true" focusable="false" viewBox="0 0 640 640" width="30" height="30">
                <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                ~;
my $fa_star_off = $fa_header . q~
                    <path fill="currentColor" d="M528.1 171.5L382 150.2 316.7 17c-11.7-23.6-45.6-23.9-57.4 0L194 150.2 47.9 171.5c-26.2 3.8-36.7 36.1-17.7 54.6l105.7 103-25 145.5c-4.5 26.2 23 46 46.4 33.7L288 439.6l130.7 68.7c23.4 12.3 50.9-7.5 46.4-33.7l-25-145.5 105.7-103c19-18.5 8.5-50.8-17.7-54.6zM388.6 312.3l23.7 138.1L288 385.4l-124.3 65.1 23.7-138.1-100.6-98 139-20.2 62.2-126 62.2 126 139 20.2-100.6 98z"/>
                    </svg>~;
my $fa_star_on = $fa_header . q~
                    <path fill="currentColor" d="M259.3 17.8L194 150.2 47.9 171.5c-26.2 3.8-36.7 36.1-17.7 54.6l105.7 103-25 145.5c-4.5 26.3 23 46 46.4 33.7L288 439.6l130.7 68.7c23.4 12.3 50.9-7.5 46.4-33.7l-25-145.5 105.7-103c19-18.5 8.5-50.8-17.7-54.6L382 150.2 316.7 17c-11.7-23.6-45.6-23.9-57.4 0z"/>
                    </svg>~;
my $fa_gear = $fa_header . q~
                    <path fill="currentColor" d="M259.1 73.5C262.1 58.7 275.2 48 290.4 48L350.2 48C365.4 48 378.5 58.7 381.5 73.5L396 143.5C410.1 149.5 423.3 157.2 435.3 166.3L503.1 143.8C517.5 139 533.3 145 540.9 158.2L570.8 210C578.4 223.2 575.7 239.8 564.3 249.9L511 297.3C511.9 304.7 512.3 312.3 512.3 320C512.3 327.7 511.8 335.3 511 342.7L564.4 390.2C575.8 400.3 578.4 417 570.9 430.1L541 481.9C533.4 495 517.6 501.1 503.2 496.3L435.4 473.8C423.3 482.9 410.1 490.5 396.1 496.6L381.7 566.5C378.6 581.4 365.5 592 350.4 592L290.6 592C275.4 592 262.3 581.3 259.3 566.5L244.9 496.6C230.8 490.6 217.7 482.9 205.6 473.8L137.5 496.3C123.1 501.1 107.3 495.1 99.7 481.9L69.8 430.1C62.2 416.9 64.9 400.3 76.3 390.2L129.7 342.7C128.8 335.3 128.4 327.7 128.4 320C128.4 312.3 128.9 304.7 129.7 297.3L76.3 249.8C64.9 239.7 62.3 223 69.8 209.9L99.7 158.1C107.3 144.9 123.1 138.9 137.5 143.7L205.3 166.2C217.4 157.1 230.6 149.5 244.6 143.4L259.1 73.5zM320.3 400C364.5 399.8 400.2 363.9 400 319.7C399.8 275.5 363.9 239.8 319.7 240C275.5 240.2 239.8 276.1 240 320.3C240.2 364.5 276.1 400.2 320.3 400z"/></svg>~;
my $fa_list = $fa_header . q~
                    <path fill="currentColor" d="M197.8 100.3C208.7 107.9 211.3 122.9 203.7 133.7L147.7 213.7C143.6 219.5 137.2 223.2 130.1 223.8C123 224.4 116 222 111 217L71 177C61.7 167.6 61.7 152.4 71 143C80.3 133.6 95.6 133.7 105 143L124.8 162.8L164.4 106.2C172 95.3 187 92.7 197.8 100.3zM197.8 260.3C208.7 267.9 211.3 282.9 203.7 293.7L147.7 373.7C143.6 379.5 137.2 383.2 130.1 383.8C123 384.4 116 382 111 377L71 337C61.6 327.6 61.6 312.4 71 303.1C80.4 293.8 95.6 293.7 104.9 303.1L124.7 322.9L164.3 266.3C171.9 255.4 186.9 252.8 197.7 260.4zM288 160C288 142.3 302.3 128 320 128L544 128C561.7 128 576 142.3 576 160C576 177.7 561.7 192 544 192L320 192C302.3 192 288 177.7 288 160zM288 320C288 302.3 302.3 288 320 288L544 288C561.7 288 576 302.3 576 320C576 337.7 561.7 352 544 352L320 352C302.3 352 288 337.7 288 320zM224 480C224 462.3 238.3 448 256 448L544 448C561.7 448 576 462.3 576 480C576 497.7 561.7 512 544 512L256 512C238.3 512 224 497.7 224 480zM128 440C150.1 440 168 457.9 168 480C168 502.1 150.1 520 128 520C105.9 520 88 502.1 88 480C88 457.9 105.9 440 128 440z"/></svg>~;
my $fa_rotate_left = $fa_header . q~
                    <path fill="currentColor" d="M88 256L232 256C241.7 256 250.5 250.2 254.2 241.2C257.9 232.2 255.9 221.9 249 215L202.3 168.3C277.6 109.7 386.6 115 455.8 184.2C530.8 259.2 530.8 380.7 455.8 455.7C380.8 530.7 259.3 530.7 184.3 455.7C174.1 445.5 165.3 434.4 157.9 422.7C148.4 407.8 128.6 403.4 113.7 412.9C98.8 422.4 94.4 442.2 103.9 457.1C113.7 472.7 125.4 487.5 139 501C239 601 401 601 501 501C601 401 601 239 501 139C406.8 44.7 257.3 39.3 156.7 122.8L105 71C98.1 64.2 87.8 62.1 78.8 65.8C69.8 69.5 64 78.3 64 88L64 232C64 245.3 74.7 256 88 256z"/>
                    </svg>~;
my $fa_info = $fa_header . q~
                    <path fill="currentColor" d="M320 576C461.4 576 576 461.4 576 320C576 178.6 461.4 64 320 64C178.6 64 64 178.6 64 320C64 461.4 178.6 576 320 576zM288 224C288 206.3 302.3 192 320 192C337.7 192 352 206.3 352 224C352 241.7 337.7 256 320 256C302.3 256 288 241.7 288 224zM280 288L328 288C341.3 288 352 298.7 352 312L352 400L360 400C373.3 400 384 410.7 384 424C384 437.3 373.3 448 360 448L280 448C266.7 448 256 437.3 256 424C256 410.7 266.7 400 280 400L304 400L304 336L280 336C266.7 336 256 325.3 256 312C256 298.7 266.7 288 280 288z"/>
                    </svg>~;

# Preflight checks
print STDERR "\n+-----Welcome to Taskpony! ----------+\n";
print STDERR "|  [X] Install Taskpony              |\n";
print STDERR "|  [ ] Do the thing                  |\n";
print STDERR "|  [ ] Buy milk                      |\n";
print STDERR "+------------------------------------+\n\n";

connect_db();                   # Connect to the database
config_load();                  # Load saved config values

####################################
# Start main loop

my $static_dir = catdir($FindBin::Bin);

my $app = sub {
    my $env = shift; 
    my $req = Plack::Request->new($env);
    my $res = Plack::Response->new(200);

    if (not $dbh->ping) { connect_db(); }      # Reconnect to DB if needed

    # Load config
    # !!
    # config_load();

    # Global modifiers
    $show_completed = $req->param('sc') // 0;   # If ?sc=1 we want to show completed tasks. 
    $list_id = $req->param('lid') || 0;         # Select list from ?lid= param, or 0 if not set

    # If no list lid specified by argument, get the active list from ConfigTb to provide consistency to user
    if ($list_id == 0) {
        $list_id = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'active_list' LIMIT 1");
        debug("List id (lid) was specified, using active list id from ConfigTb of: $list_id");
        } else { # list id was specified, update active list in ConfigTb with it.
        debug("List id (lid) was specified. Updating active_list id in ConfigTb to: $list_id");
        $dbh->do(
            "INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?",
            undef,
            'active_list',
            $list_id,
            $list_id
            ) or print STDERR "WARNING: Failed to set active_list: " . $dbh->errstr;
        }

    # Get name of active list for later us
    $list_name = single_db_value("SELECT `Title` FROM ListsTb WHERE `id` = ?", $list_id) || 'Unknown List';

    # Start building page
    my $html = header();

    ###############################################
    # Step through named paths
    ###############################################


    ###############################################
    # Set TASK nn as Status 2 in TasksTb (Completed)
    if ($req->path eq "/complete") {

        # Accept task_id from GET or POST
        my $task_id = $req->param('task_id') // 0;

        if ($task_id > 0) {
            my $sth = $dbh->prepare(
                'UPDATE TasksTb SET Status = 2, CompletedDate = CURRENT_TIMESTAMP WHERE id = ?'
            );
            eval { $sth->execute($task_id); 1 } or print STDERR "Update failed: $@";

            debug("Task $task_id marked as complete");
            add_alert("Task #$task_id marked as completed");
        }

        # Always redirect
        $res->redirect('/');
        return $res->finalize;
    }
    # End /complete

    ###############################################
    # Set TASK nn as Status 1 in TasksTb (Active)
    if ($req->path eq "/ust") {
        if ($req->method && uc($req->method) eq 'GET') {
            my $task_id = $req->param('task_id') // 0;
            
            if ($task_id > 0) {
                my $sth = $dbh->prepare('UPDATE TasksTb SET Status = 1, AddedDate = CURRENT_TIMESTAMP, CompletedDate = NULL WHERE id = ?');
                eval { $sth->execute($task_id); 1 } or print STDERR "Update failed: $@";
                debug("Task $task_id marked as active again");
                add_alert("Task #$task_id re-activated.");
            }
        }
        $res->redirect('/?sc=1'); # Redirect back to completed tasks view and show completed tasks, as we probably came from there
        return $res->finalize;
        }
    # End /ust

    ###############################################
    # Handle setting a list as default
    if ($req->path eq "/set_default_list") {
        if ($req->method && uc($req->method) eq 'GET') {
            my $lid = $req->param('id');

            if ($lid > 1) { # Don't allow setting "All Lists" as default
                print STDERR "Setting list $lid as default list.\n";
                single_db_value('UPDATE ListsTb SET IsDefault = 0 WHERE IsDefault = 1'); # Clear current default
                my $sth = $dbh->prepare('UPDATE ListsTb SET IsDefault = 1 WHERE id = ?');
                eval { $sth->execute($lid); 1 } or print STDERR "WARN: Set default lid update failed: $@";                
                add_alert("List #$lid set as default.");
                }
            }
        $res->redirect('/lists'); # Redirect back to completed tasks view and show completed tasks, as we probably came from there
        return $res->finalize;
        }
    # End /set_default_list

    ###############################################
    # Create a new task
    if ($req->path eq "/add") {

        # If POST, sanitize input and insert into DB
        if ($req->method && uc($req->method) eq 'POST') {
            my $title = sanitize($req->param('Title') // '');
            my $desc  = sanitize($req->param('Description') // '');

            if (length $title) {
                my $sth = $dbh->prepare(
                    'INSERT INTO TasksTb (Title, Description, ListId) VALUES (?, ?, ?)'
                    );
                eval { $sth->execute($title, $desc, $list_id); 1 } or print STDERR "WARN: Task insert into list $list_id failed: $@";
                }

            add_alert("Task '$title' added.");
            $res->redirect('/');
            return $res->finalize;
            }

        # If page, show the add-task form
        my $html = header();
        $html .= qq~
            <div class="container py-4">
                <h3 class="mb-3">Add Task</h3>
                <form method="post" action="/add" class="row g-3">
                <div class="col-12">
                    <label class="form-label">Title</label>
                    <input name="Title" class="form-control" required maxlength="255" />
                </div>
                <div class="col-12">
                    <label class="form-label">Description</label>
                    <textarea name="Description" class="form-control" rows="4" maxlength="2000"></textarea>
                </div>
                <div class="col-12">
                    <button class="btn btn-primary" type="submit">Create Task</button>
                    <a class="btn btn-secondary" href="/">Cancel</a>
                </div>
                </form>
            </div>
            ~;
        $html .= footer();
        $res->body($html);
        return $res->finalize;
        }
    # End /add

    ###############################################
    # Handle editing a task
    if ($req->path eq "/edittask") {
        my $task_id = $req->param('id') // 0;

        # If POST, update the task in DB and redirect
        if ($req->method && uc($req->method) eq 'POST') {
            my $title = sanitize($req->param('Title') // '');
            my $desc  = sanitize($req->param('Description') // '');
            my $list_id = $req->param('ListId') // 0;

            if (length $title && $task_id > 0 && $list_id > 1) {
                my $sth = $dbh->prepare(
                    'UPDATE TasksTb SET Title = ?, Description = ?, ListId = ? WHERE id = ?'
                    );
                eval { $sth->execute($title, $desc, $list_id, $task_id); 1 } or print STDERR "Task update failed: $@";
                debug("Task $task_id updated");
                }

            add_alert("Task $task_id updated.");
            $res->redirect('/');
            return $res->finalize;
            } # End receive form

        # Display edit form        
        if ($task_id > 0) {
            my $sth = $dbh->prepare('SELECT id, Status, Title, Description, ListId FROM TasksTb WHERE id = ?');
            $sth->execute($task_id);
            my $task = $sth->fetchrow_hashref();

            if ($task) {
                my $html = header();
                
                # Build list dropdown
                my $list_dropdown = qq~<select name="ListId" class="form-select" required>~;
                my $list_sth = $dbh->prepare('SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL AND id > 1 ORDER BY Title ASC');
                $list_sth->execute();
                
                # Build list 
                while (my $list= $list_sth->fetchrow_hashref()) {
                    my $selected = ($list->{'id'} == $task->{'ListId'}) ? ' selected' : '';
                    my $title = html_escape($list->{'Title'});
                    $list_dropdown .= qq~<option value="$list->{'id'}"$selected>$title</option>~;
                    }
                $list_dropdown .= '</select>';

                my $task_status = 'Completed';
                if ($task->{'Status'} == 1) { $task_status = 'Active'; }

                $html .= start_card("Edit Task #$task_id - $task_status", $fa_info);

                $html .= qq~
                            <form method="post" action="/edittask?id=$task_id" class="row g-3">

                                <div class="col-12">
                                <label class="form-label">Title</label>
                                <input
                                    name="Title"
                                    class="form-control bg-dark text-white border-secondary"
                                    required
                                    maxlength="255"
                                    value="~ . html_escape($task->{'Title'}) . qq~"
                                />
                                </div>

                                <div class="col-12">
                                <label class="form-label">Description</label>
                                <textarea
                                    name="Description"
                                    class="form-control bg-dark text-white border-secondary"
                                    rows="4"
                                    maxlength="2000"
                                >~ . html_escape($task->{'Description'}) . qq~</textarea>
                                </div>

                                <div class="col-12">
                                <label class="form-label">List</label>
                                $list_dropdown
                                </div>

                                <div class="col-12 d-flex align-items-center">
                                <button class="btn btn-primary" type="submit">Save Task</button>
                                <a class="btn btn-secondary ms-2" href="/">Cancel</a>

                                <div class="ms-auto">
                                ~;

                                if ($task->{'Status'} == 1) {
                                    $html .= qq~
                                    <a class="btn btn-warning" href="/complete?task_id=$task_id">Set Task as Completed</a>
                                    ~;
                                    } else {
                                    $html .= qq~
                                    <a class="btn btn-warning" href="/ust?task_id=$task_id">Set Task as Active</a>
                                    ~;
                                    }
                                    

                                $html .= qq~
                                    <a class="btn btn-danger ms-2" href="/?delete_task=$task_id">Delete Task</a>
                                </div>
                                </div>

                            </form>
                            </div>
                        </div>

                        </div>
                    </div>
                    </div>
                    ~;

                $html .= footer();
                $res->body($html);
                return $res->finalize;
                }
            }

        $res->status(404);
        $res->body("Task not found");
        return $res->finalize;
        }
    # End /edittask

    ###############################################
    # Lists Management page
    if ($req->path eq "/lists") {
        my $html = header();

        # If POST, handle add/edit/delete list
        if ($req->method && uc($req->method) eq 'POST') {
            my $action = $req->param('action') // '';
            my $list_id = $req->param('list_id') // 0;
            my $title = sanitize($req->param('Title') // '');
            my $desc = sanitize($req->param('Description') // '');

            if ($action eq 'add' && length $title) {
                my $sth = $dbh->prepare(
                    'INSERT INTO ListsTb (Title, Description) VALUES (?, ?)'
                    );
                eval { $sth->execute($title, $desc); 1 } or print STDERR "Insert failed: $@";
                add_alert("List '$title' added.");
                } elsif ($action eq 'edit' && $list_id > 1 && length $title) {
                my $sth = $dbh->prepare(
                    'UPDATE ListsTb SET Title = ?, Description = ? WHERE id = ?'
                    );
                eval { $sth->execute($title, $desc, $list_id); 1 } or print STDERR "Update failed: $@";
                add_alert("List updated.");                
                } elsif ($action eq 'delete' && $list_id > 1) {
                # Soft delete - set DeletedDate to current timestamp                
                my $sth = $dbh->prepare(
                    'UPDATE ListsTb SET DeletedDate = CURRENT_TIMESTAMP WHERE id = ?'
                    );
                eval { $sth->execute($list_id); 1 } or print STDERR "Delete failed: $@";
                add_alert("List deleted.");
                }

            $res->redirect('/lists');
            return $res->finalize;
            }

        # Page - Display List of Lists
        $html .= start_card('Lists Management', $fa_list);
        $html .= qq~  
                            <table class="table table-dark table-striped">
                                <thead>
                                    <tr>
                                        <th>List</th>
                                        <th>Description</th>
                                        <th>Active Tasks</th>
                                        <th>Completed Tasks</th>
                                        <th><span class="badge bg-secondary text-white" data-bs-toggle="tooltip" data-bs-placement="top" title="The default list appears at the top of the list picklist">Default</span</th>
                                        <th>Actions</th>
                                    </tr>
                                </thead>
                            <tbody>
        ~;

        # Add "All Lists" row
        my $all_active = single_db_value('SELECT COUNT(*) FROM TasksTb WHERE Status = 1') // 0;
        my $all_completed = single_db_value('SELECT COUNT(*) FROM TasksTb WHERE Status = 2') // 0;
        
        $html .= qq~
                                <tr>
                                    <td><strong><a href="/?lid=1" class="text-white text-decoration-none">All Lists</a></strong></td>
                                    <td>View tasks from all lists</td>
                                    <td><a href="/tasks-by-status?status=1" class="text-white text-decoration-none">$all_active</a></td>
                                    <td><a href="/tasks-by-status?status=2" class="text-white text-decoration-none">$all_completed</a></td>
                                    <td>&nbsp;</td>
                                    <td>&nbsp;</td>
                                </tr>
        ~;

        my $list_sth = $dbh->prepare(
            'SELECT id, Title, Description, IsDefault FROM ListsTb WHERE DeletedDate IS NULL AND id != 1 ORDER BY Title ASC'
            );  # Don't select ListsTb.id=1, "All"
        $list_sth->execute();

        # Step through lists
        while (my $list= $list_sth->fetchrow_hashref()) {
            my $active_count = single_db_value(
                'SELECT COUNT(*) FROM TasksTb WHERE ListId = ? AND Status = 1',
                $list->{'id'}
                ) // 0;
            my $completed_count = single_db_value(
                'SELECT COUNT(*) FROM TasksTb WHERE ListId = ? AND Status = 2',
                $list->{'id'}
                ) // 0;

            my $title = html_escape($list->{'Title'});
            my $desc = substr(html_escape($list->{'Description'} // ''), 0, $config->{cfg_description_short_length});
            
            # Show toggles for default list
            my $is_default_str = qq~
                <a href="/set_default_list?id=$list->{'id'}">
                <span class="badge bg-secondary text-white" data-bs-toggle="tooltip" data-bs-placement="top" title="Make this the default list">                
                    $fa_star_off
                </span>
                </a>
                ~;

            if ($list->{'IsDefault'} == 1) {
                $is_default_str = qq~
                    <span class="badge bg-success" data-bs-toggle="tooltip" data-bs-placement="top" title="This is the default list">
                        $fa_star_on
                    </span>~;
                }

            $html .= qq~
                                <tr>
                                    <td><strong><span data-bs-toggle="tooltip" data-bs-placement="top" title="Edit List Details"><a class="text-white text-decoration-none" href="/editlist?id=$list->{'id'}">$title</a></span></strong></td>
                                    <td>$desc</td>
                                    <td>$active_count</td>
                                    <td>$completed_count</td>
                                    <td>$is_default_str</td>
                                    <td>                                        
                                        <form method="post" action="/lists" style="display:inline;">
                                            <input type="hidden" name="action" value="delete" />
                                            <input type="hidden" name="list_id" value="$list->{'id'}" />
                                            <button type="submit" class="btn btn-sm btn-danger" onclick="return confirm('Permanently delete this list?');">Delete</button>                                            
                                        </form>
                                    </td>
                                </tr>
                ~;
            } # End lists loop

        $html .= qq~
                            </tbody>
                        </table>
                    </div>
                </div>

                <div class="row g-3">
                    <div class="col-md-1"></div>
                    <div class="col-md-10">
                        <div class="card card-dark text-white shadow-sm">
                            <div class="card-body">
                                <h5 class="mb-3">Add New List</h5>
                                <form method="post" action="/lists" class="row g-3">
                                    <input type="hidden" name="action" value="add" />
                                    <div class="col-12">
                                        <label class="form-label">Title</label>
                                        <input name="Title" class="form-control" required maxlength="255" />
                                    </div>
                                    <div class="col-12">
                                        <label class="form-label">Description</label>
                                        <textarea name="Description" class="form-control" rows="3" maxlength="2000"></textarea>
                                    </div>
                                    <div class="col-12">
                                        <button class="btn btn-primary" type="submit">Add List</button>
                                        <a class="btn btn-secondary" href="/">Cancel</a>
                                    </div>
                                </form>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        ~;

        $html .= footer();
        $res->body($html);
        return $res->finalize;
        } 
    # End /lists

    ###############################################
    # Handle editing a list
    if ($req->path eq "/editlist") {
        my $list_id = $req->param('id') // 0;

        # If POST, update the list in DB and redirect
        if ($req->method && uc($req->method) eq 'POST') {
            my $title = sanitize($req->param('Title') // '');
            my $desc = sanitize($req->param('Description') // '');

            if (length $title && $list_id > 1) {
                my $sth = $dbh->prepare(
                    'UPDATE ListsTb SET Title = ?, Description = ? WHERE id = ?'
                );
                eval { $sth->execute($title, $desc, $list_id); 1 } or print STDERR "Update failed: $@";
                add_alert("List '$title' updated.");
            }

            $res->redirect('/lists');
            return $res->finalize;
            }

        # If GET, show the edit-list form
        if ($list_id > 1) {
            my $sth = $dbh->prepare('SELECT id, Title, Description FROM ListsTb WHERE id = ?');
            $sth->execute($list_id);
            my $list= $sth->fetchrow_hashref();

            if ($list) {
                my $html = header();
                $html .= start_card("Edit List", $fa_list);
                $html .= qq~
                        <form method="post" action="/editlist?id=$list_id" class="row g-3">
                            <div class="col-12">
                                <label class="form-label">Title</label>
                                <input name="Title" class="form-control" required maxlength="255" value="~ . html_escape($list->{'Title'}) . qq~" />
                            </div>
                            <div class="col-12">
                                <label class="form-label">Description</label>
                                <textarea name="Description" class="form-control" rows="4" maxlength="2000">~ . html_escape($list->{'Description'} // '') . qq~</textarea>
                            </div>
                            <div class="col-12">
                                <button class="btn btn-primary" type="submit">Save List</button>
                                <a class="btn btn-secondary" href="/lists">Cancel</a>
                            </div>
                        </form>
                    </div>
                ~;
                $html .= end_card();
                $html .= footer();
                $res->body($html);
                return $res->finalize;
                }
            }

        $res->status(404);
        $res->body("List not found");
        return $res->finalize;
        }
    # End /editlist

  ###############################################
    # Handle config changes
    if ($req->path eq "/config") {
        # If POST, update the config in DB and redirect to root
        if ($req->method && uc($req->method) eq 'POST') {

            if ($req->param('save_config') eq 'true') { 
                print STDERR "Config form received\n";

                # Loop through config keys and try to get them from param
                for my $key (keys %$config) {
                    my $new_val;
                    $new_val = $req->param($key); # || $config->{$key};

                    if ($new_val) {
                        debug("Config value returned: ($key) = ($new_val) [$config->{$key}]");
                        } else { # No parameter passed for key, store existing
                        debug("No parameter passed for ($key), using existing [$config->{$key}]");
                        # Special handling for checkboxes which return void if not set
                        if ($key =~ 'cfg_include_datatable_|cfg_export_all_cols') {
                            $new_val = 'off';
                            debug("Belay that, this is a checkbox, set it to off");
                            } else {
                            $new_val = $config->{$key};
                            }
                        }

                    # Set current local config value to avoid needing to reload config
                    $config->{$key} = $new_val;

                    my $sth = $dbh->prepare(
                        "INSERT INTO ConfigTb (`key`, `value`)
                        VALUES (?, ?)
                        ON CONFLICT(`key`) DO UPDATE SET `value` = ?"
                        );
                    eval { $sth->execute($key, $new_val, $new_val); 1 } or print STDERR "WARN: Failed to store config key '$key': " . $dbh->errstr . "\n";
                    debug("Stored ($key) with ($new_val) OK");
                    } # End keys lookup               
                } 
            
            add_alert("Configuration saved");
            $res->redirect('/');
            return $res->finalize;
            }        

        ###############################################
        # Show configuration page
        my $retstr .= header();

        $retstr .= start_card("Settings", $fa_gear);
        $retstr .= qq~
                         <form method="post" action="/config" style="display:inline;">

                            <input type="hidden" name="save_config" value="true">

                            <!-- TOGGLE ROW cfg_include_datatable_search -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">                                
                                <span class="config-label">
                                    Display Search Box
                                    <span data-bs-toggle="tooltip" title="Display the search box at the top right of the tasks table"> 
                                        $fa_info
                                    </span> 
                                </span>
                                <div class="form-check form-switch m-0">
                                <input class="form-check-input" type="checkbox" name="cfg_include_datatable_search" 
                                    id="autoUpdateToggle"
                                    ~;
                                    # Precheck this if set
                                    if ($config->{'cfg_include_datatable_search'} eq 'on') { $retstr .= " checked "; }

                                    $retstr .= qq~
                                    >
                                </div>
                            </div>

                            <!-- TOGGLE ROW cfg_include_datatable_buttons -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label">                                    
                                    Display export buttons
                                    <span data-bs-toggle="tooltip" title="Display the export buttons at the end of the Tasks list - Copy, CSV, PDF, etc">
                                        $fa_info
                                    </span>
                                </span>
                                <div class="form-check form-switch m-0">
                                <input class="form-check-input" type="checkbox" name="cfg_include_datatable_buttons" 
                                    id="autoUpdateToggle"
                                    ~;

                                    # Precheck this if set
                                    if ($config->{'cfg_include_datatable_buttons'} eq 'on') { $retstr .= " checked "; }

                                    $retstr .= qq~
                                    >
                                </div>
                            </div>

                            <!-- TOGGLE ROW cfg_export_all_cols -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label">                                    
                                    Export date and list
                                    <span data-bs-toggle="tooltip" title="When using the export buttons, $app_title will normally just export the Task name. Enable this to include the date and list for each task">
                                        $fa_info
                                    </span>
                                </span>
                                <div class="form-check form-switch m-0">
                                <input class="form-check-input" type="checkbox" name="cfg_export_all_cols" 
                                    id="autoUpdateToggle"
                                    ~;

                                    # Precheck this if set
                                    if ($config->{'cfg_export_all_cols'} eq 'on') { $retstr .= " checked "; }

                                    $retstr .= qq~
                                    >
                                </div>
                            </div>                            

                            <!-- PICKLIST row cfg_header_colour -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label">                                    
                                    Title Background Colour
                                    <span data-bs-toggle="tooltip" title="Select colour for panel header backgrounds">
                                        $fa_info
                                    </span>
                                <span class="badge bg-$config->{cfg_header_colour}">Currently '$config->{cfg_header_colour}'</span>
                                </span>
                                
                                <div class="mb-3">
                                    <select class="form-select" id="themeColor" name="cfg_header_colour">                                        
                                        <option value="$config->{cfg_header_colour}" class="bg-$config->{cfg_header_colour} text-white">Current choice</option>
                                        <option value="primary" class="bg-primary text-white">Primary</option>
                                        <option value="secondary" class="bg-secondary text-white">Secondary</option>
                                        <option value="success" class="bg-success text-white">Success</option>
                                        <option value="danger" class="bg-danger text-white">Danger</option>
                                        <option value="warning" class="bg-warning text-dark">Warning</option>
                                        <option value="info" class="bg-info text-dark">Info</option>
                                        <option value="light" class="bg-light text-dark">Light</option>
                                        <option value="dark" class="bg-dark text-white">Dark</option>
                                    </select>
                                </div>
                            </div>

                            <!-- NUMBER ROW cfg_task_pagination_length -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label">                                    
                                    Number of Tasks to show on each page
                                    <span data-bs-toggle="tooltip" title="How many tasks to show on each page before paginating">
                                        $fa_info
                                    </span>
                                </span>

                                <input type="number" class="form-control w-50" 
                                    value="$config->{cfg_task_pagination_length}" 
                                    name="cfg_task_pagination_length">
                            </div>

                            <!-- NUMBER ROW cfg_description_short_length -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label">                                    
                                    Max length of popup task description
                                    <span data-bs-toggle="tooltip" title="Maximum characters to display of the popup Task description in the Task list before truncating it">
                                        $fa_info
                                    </span>
                                </span>

                                <input type="number" class="form-control w-50" 
                                    value="$config->{cfg_description_short_length}" 
                                    name="cfg_description_short_length">
                            </div>

                            <!-- NUMBER ROW cfg_description_short_length -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label">                                    
                                    Max length of List name in Tasks list
                                    <span data-bs-toggle="tooltip" title="Maximum characters to display of the List title in the rightmost column before truncating it in the Tasks list">
                                        $fa_info
                                    </span>
                                </span>

                                <input type="number" class="form-control w-50" 
                                    value="$config->{cfg_list_short_length}" 
                                    name="cfg_list_short_length">
                            </div>                            

                            <div class="text-end">
                                <button class="btn btn-primary">Save Settings</button>
                            </div>
                        </form>
                    </div>
                </div>
            </div>
        </div>                    
        ~;

        $retstr .= footer();
        $res->body($retstr);
        return $res->finalize;
        }
    # End /config

    ###############################################
    # End named paths

    ###############################################
    # Default page - If no other paths have taken the request then land here, list tasks and the quickadd form

    # /?delete_task=nn - Delete task nn 
    my $delete_task = $req->param('delete_task') // 0;        
    if ($delete_task > 0) {
        my $sth = $dbh->prepare('DELETE FROM TasksTb WHERE id = ?');
        eval { $sth->execute($delete_task); 1 } or print STDERR "WARN: Delete TasksTb.id=$delete_task failed: $@";
        add_alert("Task #$delete_task deleted.");
        $res->redirect('/'); # Redirect back to default page
        return $res->finalize;
        }

        
        # # Start the main box
        # $html .= qq~
        #     <div class="row g-1">
        #         <div class="col-md-1">
        #         </div>
        #         <div class="col-md-10">
        #             <div class="card card-dark text-white shadow-sm">
        #                 <div class="card-header bg-$config->{cfg_header_colour} text-white">       
        #     ~;

        # # Only show quick input box if we have a specific list selected
        # if ($list_id != 1) { 
        #     $html .= qq~            
        #                     <form method="post" action="/add" class="row g-3">
        #                         <div class="col-1">
        #                         </div>
        #                         <div class="col-9">
        #                             <input name="Title" autofocus class="form-control" required maxlength="200" placeholder="Add new task to '$list_name' " />
        #                         </div>
        #                         <div class="col-2">
        #                             <button class="btn btn-primary" type="submit">Add</button>   
        #                         </div>
        #                     </form>
        #             ~;
        #     } else { # Show banner for all lists instead
        #         if ($show_completed == 1) {
        #             $html .= "Showing completed tasks from all lists";
        #             } else {
        #             $html .= "Showing active tasks from all lists";
        #             }
        #         } # End all lists quick add check

        # $html .= qq~
        #                 </div>
        #                 <div class="card-body">
        #     ~; 

        # Set default titlebar to be the quick add form for the selected list
    my $titlebar = qq~                    
                        <form method="post" action="/add" class="d-flex align-items-center gap-2 m-0">
                            <input name="Title" autofocus class="form-control" required maxlength="200" placeholder="Add new task to '$list_name' " />
                            <button class="btn btn-primary" type="submit">Add</button>
                        </form>
                    ~;
    # If showing all lists, change titlebar to show what is being displayed instead of the form
    if ($list_id == 1) {
        if ($show_completed == 1) {
            $titlebar = "Showing completed tasks from all lists";
            } else {
            $titlebar = "Showing active tasks from all lists";
            }
        }

    $html .= start_card($titlebar);

    ####################################
    # Show main list of tasks

    # Show completed tasks if ?sc=1
    if ($show_completed == 1) {
        $html .= show_tasks(2,$list_id);
        } else { # Else show active tasks
        $html .= show_tasks(1,$list_id);
        }

    # End list of tasks, continue with box
    #####################################

    $html .= end_card();

    # $html .= qq~
    #                 </div>
    #             </div>
    #         </div>
    #     </div>
    #     ~;

    $html .= footer();
    $res->body($html);
    return $res->finalize;
    };   # End main loop, pages and paths handling

# builder {
#     # Enable Static middleware for specific paths, including favicon.ico  Launches main loop on first run.
#     enable 'Plack::Middleware::Static', 
#         path => qr{^/(favicon.ico|robots.txt|taskpony-logo.png|/css/datatables.min.css)},
#         root => $static_dir;

#     $app;
#     };
builder {
    # Enable Static middleware for specific paths, including favicon.ico  Launches main loop on first run.
    enable 'Plack::Middleware::Static', 
        path => qr{^/static/},
        root => $static_dir;
    $app;
    };

###############################################
# Functions
###############################################

###############################################
# connect_db()
# Checks whether the sqlite database file exists and if not, creates it, populates schema, and connects to it
sub connect_db { 
    # Check database exists. 
    if (! -e $db_path) {
        # Database file does not exist, so create it and initialise it.
        print STDERR "Database file $db_path not found. Assuming new install and creating new database\n";
        # Ensure data directory exists
        my ($data_dir) = $db_path =~ m{^(.*)/[^/]+$};

        if (! -d $data_dir) {
            print STDERR "Data directory $data_dir does not exist, creating it now.\n";
            mkdir $data_dir or print STDERR "FATAL: Inability to create data directory $data_dir to create the database file, $db_path\n";

            if (! -d $data_dir) {
                print STDERR "I tried to create the data directory $data_dir but it still does not exist. Cannot continue.\n";
                exit 1;
                }
            }

        print STDERR "----------------------------------------------------\n";
        print STDERR "Welcome to $app_title!\n";
        print STDERR "----------------------------------------------------\n\n";

        # Create new database connection which will autocreate the new database file
        $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
            RaiseError => 1,
            AutoCommit => 1,
            }) or die $DBI::errstr;

        initialise_database();  # Create tables etc.

        } else {
        print STDERR "Database file $db_path found, connecting to existing database.\n";

        # The database does exist, so connect to it.
        $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
            RaiseError => 1,
            AutoCommit => 1,
            }) or die $DBI::errstr;
        }

    # Check for any needed schema upgrades each time we connect
    check_database_upgrade(); 
    } 
    # End connect_db()

###############################################
# initialise_database
# Run-safe initialise of database scema. Starting with v.1 and upgrading as needed.

# Create the v.1 database schema in a new database. New DB is created and we are connected via the global $dbh
sub initialise_database { 

    ###############################################
    # Create ConfigTb
    print STDERR "Creating ConfigTb table.\n";
    $dbh->do(qq~
            CREATE TABLE IF NOT EXISTS ConfigTb (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                key TEXT UNIQUE,
                value TEXT
                );
        ~) or print STDERR "WARN: Failed to create ConfigTb: " . $dbh->errstr;

    print STDERR "ConfigTb created. Populating.\n";
    $dbh->do(qq~
            INSERT INTO ConfigTb (key, value) VALUES 
            ('database_schema_version', '1'),
            ('active_list', '2'),
            ('cfg_task_pagination_length', '$config->{'cfg_task_pagination_length'}'),
            ('cfg_description_short_length', '$config->{'cfg_description_short_length'}'),
            ('cfg_list_short_length', '$config->{'cfg_list_short_length'}'),
            ('cfg_include_datatable_buttons', '$config->{'cfg_include_datatable_buttons'}'),
            ('cfg_header_colour', '$config->{'cfg_header_colour'}')
            ;
        ~) or print STDERR "WARN: Failed to populate ConfigTb: " . $dbh->errstr;

    ###############################################
    # Create ListsTb
    print STDERR "Creating ListsTb table.\n";
    $dbh->do(qq~
            CREATE TABLE IF NOT EXISTS ListsTb (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                Title TEXT NOT NULL,
                Description TEXT,
                CreatedDate TEXT DEFAULT CURRENT_TIMESTAMP,
                DeletedDate TEXT,
                Colour TEXT,
                IsDefault INTEGER NOT NULL DEFAULT 0
                );
        ~) or print STDERR "WARN: Failed to create ListsTb: " . $dbh->errstr;

    # Populate with a default list
    print STDERR "ListsTb created. Populating with default lists.\n";
    $dbh->do(qq~
        INSERT INTO ListsTb (id, Title, Description, IsDefault) VALUES 
        (1, 'All Lists', 'View tasks from all lists', 0),
        (2, 'Main', 'Main day to day list', 1) 
        ON CONFLICT(id) DO NOTHING;
        ~) or print STDERR "WARN: Failed to populate ListsTb: " . $dbh->errstr;

    ###############################################
    # Create TasksTb
    print STDERR "Creating TasksTb table.\n";
    $dbh->do(qq~
        CREATE TABLE IF NOT EXISTS TasksTb (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            Status INTEGER DEFAULT 1, -- 1 = Active, 2 = Deferred, 3 = Completed
            Title TEXT,
            Description TEXT,
            ListId INTEGER,
            AddedDate TEXT DEFAULT CURRENT_TIMESTAMP,
            StartDate TEXT,
            CompletedDate TEXT
            );
        ~) or print STDERR "Failed to create TasksTb: " . $dbh->errstr;

    # Populate with some sample tasks
    print STDERR "TasksTb created. Populating with sample tasks.\n";
    $dbh->do(qq~
        INSERT INTO TasksTb (Title, Description, ListId) VALUES
        ('Sample Task 1', 'This is a sample task description.', 2),
        ('Sample Task 2', 'Another sample task for demonstration.', 2),
        ('Sample Task 3', 'Yet another task to show how it works.', 2);
        ~) or print STDERR "WARN: Failed to populate TasksTb: " . $dbh->errstr;

    print STDERR "Database initialisation complete, schema version 1.\n";

}    # End initialise_database()

###############################################
# check_database_upgrade()
# Check the database schema version and apply any needed upgrades
sub check_database_upgrade  {
    # Check database_schema_version in ConfigTb and compare to this script's $database_schema_version  - assume v.1 if it's missing
    my $current_db_version = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'database_schema_version' LIMIT 1") || 1;

    if ($current_db_version < $database_schema_version) {
        print STDERR "INFO: Database schema version is $current_db_version - $app_title requires schema $database_schema_version.\n";

        if ($current_db_version == 1) {
            ###############################################
            # Add schema step changes here, v.1 to v.2
            print STDERR "Upgrading database schema from version 1 to version 2.\n";

            if ($current_db_version == 2) {
                # !!! Add upgrade steps here for version 1 to 2 upgrade. If error, return without updating version number 
                }

            # Repeat for each version upgrade step as needed
            ###############################################

            # After successfully applying upgrades, update the version number in ConfigTb
            $dbh->do(
                "UPDATE ConfigTb SET `value` = ? WHERE `key` = 'database_schema_version'",
                undef,
                $database_schema_version
                ) or print STDERR "WARN: Failed to update database schema version: " . $dbh->errstr;

            print STDERR "INFO: Database schema successfully upgraded from $current_db_version to version $database_schema_version.\n";
            }
        # Database schema is already at required version
        } else {
        print STDERR "Preflight checks: Database schema version is up to date at version $current_db_version.\n";
        }
    } 
    # End check_database_upgrade()

###############################################
# header() Return HTML header including CDN loads for Bootstrap, Datatables and Fontawesome
sub header { 
    my $retstr = qq~
    <!doctype html>
    <html lang="en" class="dark">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>$app_title / $list_name</title>

    <link rel="icon" href="/favicon.ico" type="image/x-icon">

     <link rel="stylesheet" href="/static/css/jquery.dataTables.min.css">
    <link rel="stylesheet" href="/static/css/buttons.dataTables.min.css">
    <link rel="stylesheet" href="/static/css/bootstrap.min.css">

    <script src="/static/js/jquery.min.js"></script>
    <script src="/static/js/jquery.dataTables.min.js"></script>

    <script src="/static/js/dataTables.buttons.min.js"></script>
    <script src="/static/js/buttons.html5.min.js"></script>
    <script src="/static/js/buttons.print.min.js"></script>

    <script src="/static/js/jszip.min.js"></script>
    <script src="/static/js/pdfmake.min.js"></script>
    <script src="/static/js/vfs_fonts.js"></script>

    <script src="/static/js/bootstrap.bundle.min.js"></script>

    <style>
        body { background-color: #0b1220; }
        .card-dark { background-color: #0f1724; border-color: rgba(255,255,255,0.05); }
        .muted { color: rgba(255,255,255,0.65); }
    </style>

    </head>
    <body class="text-white">
    <div class="container py-1">
        <div class="d-flex justify-content-between align-items-center">
            <div>
                <h3 class="mb-0"><a href="/" class="text-white text-decoration-none"><img src="/static/taskpony-logo.png" width="85"> $app_title</a> / 
                ~;
    
    # Add the list selection pulldown
    $retstr .= list_pulldown($list_id);  

    $retstr .= qq~
            </div>

            <div class="d-flex gap-2">
            <a href="/lists"
                class="btn btn-secondary d-inline-flex align-items-center">
                Lists
            </a>

            <a href="/config"
                class="btn btn-secondary d-inline-flex align-items-center justify-content-center btn-icon">
                $fa_gear
            </a>
            </div>

            </h3>
        </div>
    </div>
    ~;

    return $retstr;
    }
    # End header()

###############################################
# footer() Return standard HTML footer
sub footer { # Return standard HTML footer
    my $retstr = show_alert();  # If there is an alert in ConfigTb waiting to be shown, display it

    $retstr .= qq~
        <br>
        <footer class="mt-auto text-white-50 text-center fixed-bottom ">
            <p><a href="https://github.com/digdilem/taskpony">$app_title v.$app_version</a> by <a href="https://digdilem.org/" class="text-white">Digital Dilemma</a>. </p>
        </footer>

        <script>
            \$(document).ready(function() {
            \$('#tasks').DataTable({
                "paging":   true,
                "ordering": true,
                "info":     true,
                ~;

            # Show search if configured
            if ($config->{'cfg_include_datatable_search'} eq 'on') {
                $retstr .= qq~
                "searching": true,
                ~;
                } else {
                $retstr .= qq~
                "searching": false,
                ~;
                }

            # Continue
            $retstr .= qq~
                "pageLength": $config->{cfg_task_pagination_length},
                ~;

            # Show buttons if configured, otherwise show default dom
            if ($config->{'cfg_include_datatable_buttons'} eq 'on') {
                $retstr .= "dom: 'ftiBp',";
                } else {
                $retstr .= "dom: 'ftip',";
                }

            $retstr .= qq~
                buttons: [
                ~;

            # Set buttons configuration, including whether to export all columns or just the first
            if ($config->{'cfg_export_all_cols'} eq 'on') {
                    $retstr .= qq~
                    { extend: 'copy', className: 'btn btn-dark btn-sm' },
                    { extend: 'csv', className: 'btn btn-dark btn-sm' },
                    { extend: 'pdf', className: 'btn btn-dark btn-sm'},
                    { extend: 'print', className: 'btn btn-dark btn-sm' }
                    ~;
                    } else {
                    $retstr .= qq~
                    { extend: 'copy', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]}  },
                    { extend: 'csv', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]}  },
                    { extend: 'pdf', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]} },
                    { extend: 'print', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]}  }
                    ~;
                    }

            $retstr .= qq~
                ],
                "language": {
                    "emptyTable": "All tasks completed! 🎉",
                    "search": "Filter tasks:",
                    "info": "Displaying _START_ to _END_ of _TOTAL_ tasks  &nbsp; &nbsp; &nbsp;"
                }
            });
        });
        </script>

        <script>
        \$(document).ready(function(){
        \$('[data-bs-toggle="tooltip"]').tooltip();
        });
        </script>

        <script>
        setTimeout(function () {
            const alert = document.getElementById('alert1');
            if (alert) {
            alert.classList.remove('show'); // triggers Bootstrap fade-out
            setTimeout(() => alert.remove(), 150); // optional: remove once faded
            }
        }, 3000);
        </script>

        </body>
        </html>
        ~;

    return $retstr;
    }
    # End footer()

###############################################
# list_pulldown($selected_lid)
# Returns HTML for a pulldown list of available lists, with the selected list marked as selected
sub list_pulldown {
    my $selected_lid = shift || $list_id;

    # Redirect to root with ?lid=<id> when selection changes (no enclosing form required)
    my $html = qq~
        <select name="lid" 
            class="form-select form-select-sm" style="width:auto; display:inline-block; margin-left:10px;" onchange="window.location='/?lid=' + encodeURIComponent(this.value)">
        ~;

    # We should check whether there is a default list. If so, select the oldest non-deleted one.
    my $default_cnt_sql = 'SELECT COUNT(*) FROM ListsTb WHERE isDefault =1 AND DeletedDate IS NULL';
    my $default_cnt = $dbh->selectrow_array($default_cnt_sql);
    
    if ($default_cnt == 0) {
        print STDERR "Odd. There's no default, active list. Maybe it just got deleted. Making the oldest list the new default.\n";
        # Clear any old isDefault lists, even if they're isDeleted
        single_db_value('UPDATE ListsTb SET IsDefault = 0 WHERE IsDefault = 1');
        # Pick the oldest non-deleted list and set it as default
        single_db_value('UPDATE ListsTb SET IsDefault = 1 WHERE id = (SELECT id FROM ListsTb WHERE DeletedDate IS NULL AND id > 1 ORDER BY CreatedDate ASC LIMIT 1)');
        # End is there a default check
        }

    # Get lists from ListsTb
    my $sth = $dbh->prepare('SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL ORDER BY IsDefault DESC,Title ASC');
    $sth->execute();

    # Prepend the "All lists" option and then loop through, adding each. 
    while (my $row = $sth->fetchrow_hashref()) {
        my $selected = ($row->{'id'} == $selected_lid) ? ' selected' : '';
        my $title = html_escape($row->{'Title'});
        my $list_count = single_db_value( 'SELECT COUNT(*) FROM TasksTb WHERE ListId = ? AND Status = 1', $row->{'id'} ) // 0;

        if ($row->{'id'} == 1) { # All lists option
            $list_count = single_db_value( 'SELECT COUNT(*) FROM TasksTb WHERE Status = 1' ) // 0;
            $title = 'All Lists';
            }
        $html .= qq~<option value="$row->{'id'}"$selected>$title ($list_count tasks)</option>\n~;
        }

    $html .= '</select>';
    return $html;
    }
    # End list_pulldown()

###############################################
# sanitize($s)
# Sanitize a string for safe storage/display
sub sanitize {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\r?\n/ /g;            # collapse newlines
    $s =~ s/[^\t[:print:]]+//g;   # remove non-printables
    $s =~ s/^\s+|\s+$//g;         # trim
    return $s;
    }
    # End sanitize()

###############################################
# html_escape($s)
# Escape HTML special characters in a string
sub html_escape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
    }
    # End html_escape()

###############################################
# single_db_value($sql, @params)
# Execute a SQL query that returns a single value
sub single_db_value {
    my ($sql, @params) = @_;
#    print STDERR "single_db_value: Executing SQL: $sql with params: [" . join(',', @params) . "]" . "\n";
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my ($value) = $sth->fetchrow_array();
#    print STDERR "RETURNING ($value)\n";
    return $value;
    }
    # End single_db_value()

###############################################
# debug($msg)
# Print debug message if debugging is globally enabled
sub debug {
    my $msg = shift;
    if ($debug == 1) {
        print STDERR "DEBUG: $msg\n";
        }
    }

###############################################
# show_tasks($status, $list_id)
# Return HTML table of tasks with given status (1=active,2=completed) for given list_id (1=all lists)
sub show_tasks {
    my ($status, $list_id) = @_;

    # Build SQL query
    my $sql = "
        SELECT t.id, t.Title, t.Description, t.AddedDate, t.CompletedDate, p.Title AS ListTitle
        FROM TasksTb t
        LEFT JOIN ListsTb p ON t.ListId = p.id
        WHERE t.Status = ? 
        ";

    if ($list_id != 1) {  # list_id is 1, which means ALL lists. If it's not 1, then filter by list_id
        $sql .= " AND t.ListId = $list_id ";
        debug("show_tasks: Filtering tasks for list_id: [$list_id]");
        } else {
        debug("show_tasks: Showing tasks for ALL lists");
        }

    # Append ordering and finish query
    $sql .= " 
        ORDER BY t.AddedDate DESC
        ";

    my $sth = $dbh->prepare($sql);
    $sth->execute($status);

    my $retstr = qq~
        <table id="tasks" class="display hover table-striped" style="width:90%">
            <thead>
                <tr>
                    <th>&nbsp;</th>
                    <th>Title</th>
        ~;

        if ($status == 1) {  # Active tasks. Show added date
            $retstr .= "<th>Added</th>\n";
            } else { # Completed tasks. Show completed date
            $retstr .= "<th>Completed</th>\n";
            }

        $retstr .= qq~
                    <th>List</th>
                </tr>
            </thead>
            <tbody>
            ~;

    # Loop through each task and output a row for each
    while (my $a = $sth->fetchrow_hashref()) {
        my $friendly_date = qq~
            <td data-order="$a->{'AddedDate'}">
                <a href="#" data-bs-toggle="tooltip" title="Added at: $a->{'AddedDate'}">
                ~
                . human_friendly_date($a->{'AddedDate'}) . qq~</a> 
            </td>
            ~;

        if ($status != 1) { # Completed tasks, show CompletedDate instead
            $friendly_date = qq~
            <td data-order="$a->{'CompletedDate'}">
                <a href="#" data-bs-toggle="tooltip" title="Completed at: $a->{'CompletedDate'}">
                ~
                . human_friendly_date($a->{'CompletedDate'}) . qq~</a>
            </td>
            ~;
            }

        my $checkbox = '';  # Default empty
        my $title_link;
        
        # Active tasks. Show checkbox to mark complete
        if ($status == 1) {  
            $checkbox .= qq~
                <form method="post" action="/complete" style="display:inline;">
                    <input type="hidden" name="task_id" value="$a->{'id'}" />
                    <input type="checkbox" class="form-check-input" style="cursor:pointer; transform:scale(1.2);" onchange="this.form.submit();" />
                </form>
                ~;

            $title_link = qq~
                <a href="/edittask?id=$a->{'id'}" class="text-white text-decoration-none" data-bs-toggle="tooltip" title="~ .
                substr($a->{'Description'},0,$config->{'cfg_description_short_length'}) . 
                qq~">~ . html_escape($a->{'Title'}) . qq~</a>
                ~;
            } 

        # Completed tasks. Show strikethrough title and button to mark uncompleted
        if ($status == 2) { # Completed tasks
            $title_link = qq~
                <del><a href="/edittask?id=$a->{'id'}" class="text-white text-decoration-none" data-bs-toggle="tooltip" title="~. 
                substr($a->{'Description'},0,$config->{'cfg_description_short_length'}) . qq~">~ . html_escape($a->{'Title'}) . qq~</a></del>
                ~;

            $checkbox .= qq~
                <a href="/ust?task_id=$a->{'id'}&sc=1" class="btn btn-sm btn-secondary" title="Mark as uncompleted">
                $fa_rotate_left
                </a>
                ~;
            }
        
        $retstr .= qq~
            <tr>
                <td>$checkbox</td>
                <td>$title_link</td>
                $friendly_date
                <td>~ . substr(html_escape($a->{'ListTitle'} // 'Unknown'),0,$config->{cfg_list_short_length}) . qq~</td>
            </tr>
            ~;
    } # End tasks loop

    # Close table
    $retstr .= qq~
            </tbody>
        </table>
        <br><hr><br>
        ~;

    # Display a link to toggle between showing completed/active tasks
    if ($show_completed == 0) {
        $retstr .= qq~
            <a href="/?sc=1" class="btn btn-secondary btn">Show completed tasks in '$list_name'</a>
            ~;
        } else {
        $retstr .= qq~
            <a href="/" class="btn btn-secondary btn">Show active tasks in '$list_name'</a>
            ~;
        }

    return $retstr;
    }
    # End show_tasks()

###############################################
# show_alert() 
# Check ConfigTb for last_alert and if found, show it once and clear it
sub show_alert { 
    my $alert_text = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'last_alert' LIMIT 1");

    if ($alert_text) { # There is an alert pending    
        single_db_value("DELETE FROM ConfigTb WHERE `key` = 'last_alert'");

        return qq~
        <div class="row g-3 mb-2">
            <div class="col-md-3">
            </div>
            <div class="col-md-6">
              <div id="alert1" class="alert alert-success alert-dismissible fade show" role="alert">                
                $alert_text
              <button type="button" class="btn-close" data-bs-dismiss="alert"></button>

            </div>
            </div>
        </div>
        ~;
        } else {
        # No alerts to show, return empty string
        return '';
        }
    }
    # End show_alert()

###############################################
# add_alert($alert_text)
# Store an alert message in ConfigTb to be shown on next page load
sub add_alert { 
    my $alert_text = shift;
    $dbh->do(
        "INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?;",
        undef,
        'last_alert',
        $alert_text,
        $alert_text
        ) or print STDERR "Failed to set last_alert: " . $dbh->errstr;
    }
    # End add_alert()

###############################################
# human_friendly_date($db_date)
# Convert a database datetime string into a human friendly relative time string
sub human_friendly_date {
    my ($db_date) = @_;
    return '' unless defined $db_date;
    
    # Parse the database datetime (format: YYYY-MM-DD HH:MM:SS)
    my ($year, $month, $day, $hour, $min, $sec) = 
        $db_date =~ /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/;
    
    return $db_date unless $year;  # Return original if parse fails
    
    # Create Unix timestamp for the db date    
    my $db_time = timelocal($sec, $min, $hour, $day, $month - 1, $year);
    my $now = time();
    my $diff_seconds = $now - $db_time;
    
    return 'Just now' if $diff_seconds < 60;
    
    my $diff_minutes = int($diff_seconds / 60);
    return "$diff_minutes minute" . ($diff_minutes == 1 ? '' : 's') . " ago" if $diff_minutes < 60;
    
    my $diff_hours = int($diff_seconds / 3600);
    return "$diff_hours hour" . ($diff_hours == 1 ? '' : 's') . " ago" if $diff_hours < 24;
    
    my $diff_days = int($diff_seconds / 86400);
    return 'Yesterday' if $diff_days == 1;
    return "$diff_days days ago" if $diff_days < 7;
    
    my $diff_weeks = int($diff_days / 7);
    return "$diff_weeks week" . ($diff_weeks == 1 ? '' : 's') . " ago" if $diff_weeks < 4;
    
    my $diff_months = int($diff_days / 30);
    return "$diff_months month" . ($diff_months == 1 ? '' : 's') . " ago" if $diff_months < 12;
    
    my $diff_years = int($diff_days / 365);
    return "$diff_years year" . ($diff_years == 1 ? '' : 's') . " ago";
    }
    # End human_friendly_date()

###############################################
# config_load()
# Load cfg_ configuration values from ConfigTb
sub config_load {
    print STDERR "Loading configuration\n";

    # List through $config keys and lead each of them from ConfigTb
    for my $key (keys %$config) {
        my $saved_value = single_db_value("SELECT value FROM ConfigTb WHERE key = '$key'");
        if ($saved_value) {
            debug("OK: Loaded value ($saved_value) from ConfigTb for ($key)");
            $config->{$key} = $saved_value;
            } else {
            debug("WARN: no value found in ConfigTb for ($key), using config default");  # Value already declared at head, no need to change
            }
        }
    }
     # End config_load()

# Open a consistent looking card
sub start_card {
    my $card_title = shift || 'Title Missing';
#    my $card_icon = shift || $fa_info;
    my $card_icon = shift || '';
    my $retstr = qq~
        <div class="container py-5">
            <div class="row justify-content-center">
                <div class="col-md-10">
                    <div class="card shadow-sm">
                        <div class="card-header bg-$config->{cfg_header_colour} text-white">
                            <h2 class="mb-0">
                                $card_title
                                ~;
    if ($card_icon ne '') {
        $retstr .= qq~
                                <div class="float-end">$card_icon</div>
                                ~;
        }
    $retstr .= qq~
                            </h2>
                        </div>

                        <div class="card-body bg-dark text-white">        ~;
    return $retstr;
    }

# Close the card
sub end_card {
    my $retstr = qq~
                        </div>
                    </div>
                </div>
            </div>
        </div>
        ~;
    return $retstr;
    }

##############################################
# End Functions

#################################################
# End of file




