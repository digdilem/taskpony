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
# Default configuration, overriden by ConfigTb values, change them via webui at /config
our $config = {
    cfg_task_pagination_length => 25,           # Number of tasks to show per page 
    cfg_description_short_length => 30,         # Number of characters to show in task list before truncating description (Cosmetic only)
    cfg_list_short_length => 20,                # Number of characters to show in list column in task display before truncating (Cosmetic only)
    cfg_include_datatable_buttons => 1,         # Include the CSV/Copy/PDF etc buttons at the bottom of each table
    cfg_header_colour => 'secondary',           # Bootstrap 5 colour of pane backgrounds
    };

###############################################
# Global variables that are used throughout - do not change these. They will not persist during app updates.
my $app_title = 'Taskpony';             # Name of app.
my $app_version = '0.01';               # Version of app
my $database_schema_version = 1;        # Current database schema version. Do not change this, it will be modified during updates.
my $db_path = '/opt/taskpony/taskpony.db';    # Path to Sqlite database file internal to docker. If not present, it will be auto created.

my $dbh;                        # Global database handle 
my $list_id = 1;                # Current list id
my $list_name;                  # Current list name
my $debug = 0;                  # Set to 1 to enable debug messages to STDERR
my $alert_text = '';            # If set, show this alert text on page load
my $show_completed = 0;         # If set to 1, show completed tasks instead of active ones

# Some inline SVG fontawesome icons to prevent including the entire svg map
my $fa_star_off = q~<svg aria-hidden="true" focusable="false" viewBox="0 0 576 512" width="24" height="24">
                    <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                    <path fill="currentColor" d="M528.1 171.5L382 150.2 316.7 17c-11.7-23.6-45.6-23.9-57.4 0L194 150.2 47.9 171.5c-26.2 3.8-36.7 36.1-17.7 54.6l105.7 103-25 145.5c-4.5 26.2 23 46 46.4 33.7L288 439.6l130.7 68.7c23.4 12.3 50.9-7.5 46.4-33.7l-25-145.5 105.7-103c19-18.5 8.5-50.8-17.7-54.6zM388.6 312.3l23.7 138.1L288 385.4l-124.3 65.1 23.7-138.1-100.6-98 139-20.2 62.2-126 62.2 126 139 20.2-100.6 98z"/>
                    </svg>~;
my $fa_star_on = q~<svg aria-hidden="true" focusable="false" viewBox="0 0 576 512" width="24" height="24">
                    <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                    <path fill="currentColor" d="M259.3 17.8L194 150.2 47.9 171.5c-26.2 3.8-36.7 36.1-17.7 54.6l105.7 103-25 145.5c-4.5 26.3 23 46 46.4 33.7L288 439.6l130.7 68.7c23.4 12.3 50.9-7.5 46.4-33.7l-25-145.5 105.7-103c19-18.5 8.5-50.8-17.7-54.6L382 150.2 316.7 17c-11.7-23.6-45.6-23.9-57.4 0z"/>
                    </svg>~;
my $fa_gear = q~<svg aria-hidden="true" focusable="false" viewBox="0 0 512 512" width="24" height="24">
                    <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                    <path fill="currentColor" d="M487.4 315.7l-42.5-24.6c4.3-23.2 4.3-47 0-70.2l42.5-24.6c12-6.9 17-22.1 11-34.7l-19.8-45.8c-6-12.6-20.3-18.6-33.6-14.6l-49 15.6c-17.9-15.4-38.7-27.3-61.4-35l-9.3-50.7C323.7 10.4 312 0 297.4 0h-54.8c-14.6 0-26.3 10.4-28.2 24.9l-9.3 50.7c-22.7 7.7-43.5 19.6-61.4 35l-49-15.6c-13.2-4-27.6 2-33.6 14.6L41.5 161.6c-6 12.6-.9 27.8 11 34.7L95 220.9c-4.3 23.2-4.3 47 0 70.2l-42.5 24.6c-12 6.9-17 22.1-11 34.7l19.8 45.8c6 12.6 20.3 18.6 33.6 14.6l49-15.6c17.9 15.4 38.7 27.3 61.4 35l9.3 50.7c1.9 14.5 13.6 24.9 28.2 24.9h54.8c14.6 0 26.3-10.4 28.2-24.9l9.3-50.7c22.7-7.7 43.5-19.6 61.4-35l49 15.6c13.2 4 27.6-2 33.6-14.6l19.8-45.8c6-12.5 1-27.7-11-34.6zM256 336c-44.2 0-80-35.8-80-80s35.8-80 80-80 80 35.8 80 80-35.8 80-80 80z"/>
                    </svg>~;
my $fa_list = q~<svg aria-hidden="true" focusable="false" viewBox="0 0 512 512" width="24" height="24">
                    <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                    <path fill="currentColor" d="M152 304c-6.6 0-12 5.4-12 12s5.4 12 12 12h208c6.6 0 12-5.4 12-12s-5.4-12-12-12H152zm0-96c-6.6 0-12 5.4-12 12s5.4 12 12 12h208c6.6 0 12-5.4 12-12s-5.4-12-12-12H152zm0-96c-6.6 0-12 5.4-12 12s5.4 12 12 12h208c6.6 0 12-5.4 12-12s-5.4-12-12-12H152zM504 256c4.4 0 8-3.6 8-8V96c0-26.5-21.5-48-48-48H48C21.5 48 0 69.5 0 96v320c0 26.5 21.5 48 48 48h184c4.4 0 8-3.6 8-8s-3.6-8-8-8H48c-17.6 0-32-14.4-32-32V96c0-17.6 14.4-32 32-32h416c17.6 0 32 14.4 32 32v152c0 4.4 3.6 8 8 8zM346.5 431l-73.9-73.9c-6.2-6.2-16.4-6.2-22.6 0l-35.3 35.3c-6.2 6.2-6.2 16.4 0 22.6l96 96c6.2 6.2 16.4 6.2 22.6 0l128-128c6.2-6.2 6.2-16.4 0-22.6l-35.3-35.3c-6.2-6.2-16.4-6.2-22.6 0L346.5 431z"/>
                    </svg>~;
my $fa_rotate_left = q~<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640" fill="currentColor" width="24" height="24">
                     <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                    <path d="M88 256L232 256C241.7 256 250.5 250.2 254.2 241.2C257.9 232.2 255.9 221.9 249 215L202.3 168.3C277.6 109.7 386.6 115 455.8 184.2C530.8 259.2 530.8 380.7 455.8 455.7C380.8 530.7 259.3 530.7 184.3 455.7C174.1 445.5 165.3 434.4 157.9 422.7C148.4 407.8 128.6 403.4 113.7 412.9C98.8 422.4 94.4 442.2 103.9 457.1C113.7 472.7 125.4 487.5 139 501C239 601 401 601 501 501C601 401 601 239 501 139C406.8 44.7 257.3 39.3 156.7 122.8L105 71C98.1 64.2 87.8 62.1 78.8 65.8C69.8 69.5 64 78.3 64 88L64 232C64 245.3 74.7 256 88 256z"/>
                    </svg>~;

# Preflight checks
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
        if ($req->method && uc($req->method) eq 'POST') {
            my $task_id = $req->param('task_id') // 0;
            
            if ($task_id > 0) {
                my $sth = $dbh->prepare('UPDATE TasksTb SET Status = 2, CompletedDate = CURRENT_TIMESTAMP WHERE id = ?');
                eval { $sth->execute($task_id); 1 } or print STDERR "Update failed: $@";
                debug("Task $task_id marked as complete");
                add_alert("Task #$task_id marked as completed.");
                }
            }
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
            }

        # If Page, show the edit-task form
        if ($task_id > 0) {
            my $sth = $dbh->prepare('SELECT id, Title, Description, ListId FROM TasksTb WHERE id = ?');
            $sth->execute($task_id);
            my $task = $sth->fetchrow_hashref();

            if ($task) {
                my $html = header();
                
                # Build list dropdown
                my $list_dropdown = qq~<select name="ListId" class="form-select" required>~;
                my $list_sth = $dbh->prepare('SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL AND id > 1 ORDER BY Title ASC');
                $list_sth->execute();
                
                while (my $list= $list_sth->fetchrow_hashref()) {
                    my $selected = ($list->{'id'} == $task->{'ListId'}) ? ' selected' : '';
                    my $title = html_escape($list->{'Title'});
                    $list_dropdown .= qq~<option value="$list->{'id'}"$selected>$title</option>~;
                    }
                $list_dropdown .= '</select>';
                
                $html .= qq~
                    <div class="container py-4">
                        <h3 class="mb-3">Edit Task</h3>
                        <form method="post" action="/edittask?id=$task_id" class="row g-3">
                        <div class="col-12">
                            <label class="form-label">Title</label>
                            <input name="Title" class="form-control" required maxlength="255" value="~ . html_escape($task->{'Title'}) . qq~" />
                        </div>
                        <div class="col-12">
                            <label class="form-label">Description</label>
                            <textarea name="Description" class="form-control" rows="4" maxlength="2000">~ . html_escape($task->{'Description'}) . qq~</textarea>
                        </div>
                        <div class="col-12">
                            <label class="form-label">List</label>
                            $list_dropdown
                        </div>
                        <br>
                        <div class="col-12">
                            <button class="btn btn-primary" type="submit">Save Task</button>
                            <a class="btn btn-secondary" href="/">Cancel</a>
                            <div class="float-end">
                                <a class="btn btn-warning" href="/complete/task_id=$task_id">Complete Task</a>
                                &nbsp;&nbsp;
                                <a class="btn btn-danger" href="/?delete_task=$task_id">Delete</a>
                            </div>
                        </div>
                        </form>
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
        $html .= qq~
            <div class="container py-4">
                <div class="row g-3 mb-5">
                    <div class="col-md-1"></div>
                    <div class="col-md-10">
                        <div class="card bg-dark border-secondary shadow-sm mb-4">
                            <div class="card-header bg-$config->{cfg_header_colour} text-white">
                                <h2 class="mb-0">Lists Management  <div class="float-end">$fa_list</div></h2>
                            </div>
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
                                    <td><strong><span data-bs-toggle="tooltip" data-bs-placement="top" title="Edit List Details"><a class="text-white text-decoration-none" href="/edit-list?id=$list->{'id'}">$title</a></span></strong></td>
                                    <td>$desc</td>
                                    <td>$active_count</td>
                                    <td>$completed_count</td>
                                    <td>$is_default_str</td>
                                    <td>                                        
                                        <form method="post" action="/lists" style="display:inline;">
                                            <input type="hidden" name="action" value="delete" />
                                            <input type="hidden" name="list_id" value="$list->{'id'}" />
                                            <button type="submit" class="btn btn-sm btn-danger" onclick="return confirm('Delete this list?');">Delete</button>                                            
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
    if ($req->path eq "/edit-list") {
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
                $html .= qq~
                    <div class="container py-4">
                        <h3 class="mb-3">Edit List</h3>
                        <form method="post" action="/edit-list?id=$list_id" class="row g-3">
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
                $html .= footer();
                $res->body($html);
                return $res->finalize;
                }
            }

        $res->status(404);
        $res->body("List not found");
        return $res->finalize;
        }
    # End /edit-list

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
                        if ($key eq 'cfg_include_datatable_buttons') {
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

        $retstr .= qq~
            <div class="container py-5">
            <div class="row justify-content-center">
                <div class="col-md-8">
                <div class="card shadow-sm">
                    <div class="card-header bg-$config->{cfg_header_colour} text-white">
                    <h2 class="mb-0">$app_title Settings <div class="float-end">$fa_gear</div></h2>
                    </div>

                    <div class="card-body bg-dark text-white">
                         <form method="post" action="/config" style="display:inline;">

                            <input type="hidden" name="save_config" value="true">

                            <!-- NUMBER ROW cfg_task_pagination_length -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label" data-bs-toggle="tooltip" title="How many tasks to show on each page before paginating">
                                Number of Tasks to show on each page
                                </span>
                                <input type="number" class="form-control w-50" 
                                    value="$config->{cfg_task_pagination_length}" 
                                    name="cfg_task_pagination_length">
                            </div>

                            <!-- NUMBER ROW cfg_description_short_length -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label" data-bs-toggle="tooltip" title="Maximum characters to display of the popup Task description in the Task list before truncating it">
                                Max length of popup task description
                                </span>
                                <input type="number" class="form-control w-50" 
                                    value="$config->{cfg_description_short_length}" 
                                    name="cfg_description_short_length">
                            </div>

                            <!-- NUMBER ROW cfg_description_short_length -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label" data-bs-toggle="tooltip" title="Maximum characters to display of the List title in the rightmost column before truncating it in the Tasks list">
                                Max length of List name in Tasks list
                                </span>
                                <input type="number" class="form-control w-50" 
                                    value="$config->{cfg_list_short_length}" 
                                    name="cfg_list_short_length">
                            </div>                    

                            <!-- TOGGLE ROW cfg_include_datatable_buttons -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label" data-bs-toggle="tooltip" title="Display the export buttons at the end of the Tasks list - Copy, CSV, PDF, etc">
                                Display export buttons
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

                            <!-- PICKLIST row cfg_header_colour -->
                            <div class="mb-3 d-flex justify-content-between align-items-center">
                                <span class="config-label" data-bs-toggle="tooltip" title="Select colour for title background">
                                Title Background Colour 
                                &nbsp;&nbsp;
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

    if ($list_id == 1) { # Show ALL Lists, but hide the quick input box as we won't know which list to add a new task to
        $html .= q~
            <div class="alert alert-primary text-center mb-3" role="alert">
                Showing 
            ~;

        if ($show_completed == 1) { 
            $html .= q~ completed ~;
            } else {
            $html .= q~ active ~;
            }
                
        $html .= q~ tasks from <strong>all </strong> list.
            </div>
            ~;    
        } 
        
        # Start the main box
        $html .= qq~
            <div class="row g-1">
                <div class="col-md-1">
                </div>
                <div class="col-md-10">
                    <div class="card card-dark text-white shadow-sm">
                        <div class="card-header bg-$config->{cfg_header_colour} text-white">       
            ~;

        # Only show quick input box if we have a specific list selected
        if ($list_id != 1) { 
            $html .= qq~            
                            <form method="post" action="/add" class="row g-3">
                                <div class="col-11">
                                    <input name="Title" autofocus class="form-control" required maxlength="200" placeholder="Add new task to '$list_name' " />
                                </div>
                                <div class="col-1">
                                    <button class="btn btn-primary" type="submit">Add</button>   
                                </div>
                            </form>
                    ~;
            }

        $html .= qq~
                        </div>
                        <div class="card-body">
            ~; 

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

    $html .= qq~
                    </div>
                </div>
            </div>
        </div>
        ~;

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
        print STDERR "Database schema version is up to date at version $current_db_version.\n";
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
            <div>
                <a href="/lists" class="btn btn-secondary btn">Lists</a> 
                &nbsp;
                <a href="/config" class="btn btn-secondary btn">
                    $fa_gear
                </i></a>
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
        <footer class="mt-auto text-white-50 text-center">
            <p><a href="https://github.com/digdilem/taskpony">$app_title v.$app_version</a> by <a href="https://digdilem.org/" class="text-white">Digital Dilemma</a>. </p>
        </footer>
        </div>

        <script>
            \$(document).ready(function() {
            \$('#tasks').DataTable({
                "paging":   true,
                "ordering": true,
                "info":     true,
                "searching": false,
                "pageLength": $config->{cfg_task_pagination_length},
                ~;

            if ($config->{'cfg_include_datatable_buttons'} eq 'on') {
#                $retstr .= "dom: 'tiBfp',";
                $retstr .= "dom: 'ftiBp',";
                } else {
#                $retstr .= "dom: 'tifp',";
                $retstr .= "dom: 'ftip',";
                }

            $retstr .= qq~
                buttons: [
                    { extend: 'copy', className: 'btn btn-dark btn-sm' },
                    { extend: 'csv', className: 'btn btn-dark btn-sm' },
                    { extend: 'pdf', className: 'btn btn-dark btn-sm' },
                    { extend: 'print', className: 'btn btn-dark btn-sm' }
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
        $html .= qq~<option value="$row->{'id'}"$selected>$title ($list_count tasks)</option>~;
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
#    debug("single_db_value: Executing SQL: $sql with params: [" . join(',', @params) . "]");
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my ($value) = $sth->fetchrow_array();
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
            <a href="#" data-bs-toggle="tooltip" title="Added at: $a->{'AddedDate'}">~
            . human_friendly_date($a->{'AddedDate'}) . qq~</a>
            ~;

        if ($status != 1) { # Completed tasks, show CompletedDate instead
            $friendly_date = qq~
            <a href="#" data-bs-toggle="tooltip" title="Completed at: $a->{'CompletedDate'}">~
            . human_friendly_date($a->{'CompletedDate'}) . qq~</a>
            ~;
            }

        my $checkbox = '&nbsp;';  # Default empty
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
                <td>$friendly_date</td>
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


##############################################
# End Functions

#################################################
# End of file




