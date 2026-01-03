#!/usr/bin/env/perl
# Taskpony - a simple perl PSGI web app for various daily tasks - https://github.com/digdilem/taskpony
# Started Christmas, 2025. Simon Avery / digdilem / https://digdilem.org 
# MIT Licence

use strict;
use warnings;

use Plack::Request;         # Perl PSGI web framework
use Plack::Response;        # Ditto
use DBI;                    # Database interface for SQLite
use Time::Local;            # For human friendly date function
use HTTP::Tiny;             # To fetch latest version from github
use JSON::PP;               # Part github json response

use Plack::Builder;         # Favicon
use File::Spec::Functions qw(catdir);
use File::Copy qw(copy move);   # For database backup copy function
use FindBin;                # To find ./static directory

# Database Path. If you install Taskpony as a Systemd service elsewhere than /opt/taskpony - you'll need to change this.
my $db_path = '/opt/taskpony/db/taskpony.db';    # Path to Sqlite database file that's valid if native or in docker. If not present, it will be auto created. 
my $bg_path = '/opt/taskpony/static/background.jpg';   # Path to the background picture, if used. This should be writeable by the taskpony process to allow uploads.

###############################################
# Default configuration. Don't change them here, use /config page.
our $config = {
    cfg_task_pagination_length => 25,           # Number of tasks to show per page 
    cfg_description_short_length => 30,         # Number of characters to show in task list before truncating description (Cosmetic only)
    cfg_list_short_length => 20,                # Number of characters to show in list column in task display before truncating (Cosmetic only)
    cfg_include_datatable_buttons => 'on',      # Include the CSV/Copy/PDF etc buttons at the bottom of each table
    cfg_include_datatable_search => 'on',       # Include the search box at the top right of each table
    cfg_export_all_cols => 'off',               # Export all columns in datatable exports, not just visible ones
    cfg_show_dates => 'on',                     # Show just tasks, hide Date and List columns in task list
    cfg_show_lists => 'on',                     # Show the Lists column in task list
    cfg_header_colour => 'success',             # Bootstrap 5 colour of pane backgrounds and highlights
    cfg_last_daily_run => 0,                    # Date of last daily run
    cfg_backup_number_to_keep => 7,             # Number of daily DB backups to keep
    cfg_version_check => 'on',                  # Whether to occasionally check for new releases
    cfg_background_image => 'on',               # Whether to display a background image
    database_schema_version => 1,               # Don't change this. True version will be read from the database on startup.
    };

###############################################
# Global variables that are used throughout - do not change these.  
my $app_title = 'Taskpony';             # Name of app.
my $app_version = '0.4';               # Version of app
my $database_schema_version = 2;        # Current database schema version. Do not change this, it will be modified during updates.
my $github_version_url = 'https://api.github.com/repos/digdilem/taskpony/releases/latest';  # Used to get latest version for upgrade notification
my $app_releases_page = 'https://github.com/digdilem/taskpony';     # Where new versions are
my $new_version_available = 0;

my $dbh;                            # Global database handle 
my $list_id = 1;                    # Current list id
my $list_name;                      # Current list name
my $debug = 0;                      # Set to 1 to enable debug messages to STDERR
my $alert_text = '';                # If set, show this alert text on page load
my $show_completed = 0;             # If set to 1, show completed tasks instead of active ones
my $db_mtime = 0;                   # Cached database file modification time for /api/dbstate
my $db_interval_check_ms = 60000;   # How many milliseconds between checking /api/dbstate for changes

# Statistics variables. Not stored in config. Recalculated periodically and updated on change.
my $calculate_stats_interval = 3600;    # Wait at least this many seconds between recalculating stats. (Only checked on web activity)
my $stats = {                           # Hashref to hold various stats for dashboard
    total_tasks => 0,
    active_tasks => 0,
    completed_tasks => 0,
    tasks_completed_today => 0,
    tasks_completed_past_week => 0,
    tasks_completed_past_month => 0,
    tasks_completed_past_year => 0,
    total_lists => 0,
    total_active_lists => 0,
    stats_last_calculated => 0,
    stats_first_task_created => 0,
    stats_first_task_created_daysago => 0,
    tasks_added_today => 0,
    repeating_tasks => 0,
    };

# Some inline SVG tabler icons to prevent including the entire svg map just for a few icons. 30px
# Copy SVG from Tabler and remove everything up to the first "<path" and also the closing "</svg>" tag.
my $icon_gear = build_tabler_icon(30,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065" /><path d="M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0" />');
my $icon_list = build_tabler_icon(30,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3.5 5.5l1.5 1.5l2.5 -2.5" /><path d="M3.5 11.5l1.5 1.5l2.5 -2.5" /><path d="M3.5 17.5l1.5 1.5l2.5 -2.5" /><path d="M11 6l9 0" /><path d="M11 12l9 0" /><path d="M11 18l9 0" />');
my $icon_rotate_left = build_tabler_icon(30,'<path d="M9 14l-4 -4l4 -4" /><path d="M5 10h11a4 4 0 1 1 0 8h-1" />');
my $icon_rotate_right = build_tabler_icon(30,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M15 14l4 -4l-4 -4" /><path d="M19 10h-11a4 4 0 1 0 0 8h1" />');
my $icon_chart = build_tabler_icon(30,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 13a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v6a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -6" /><path d="M15 9a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v10a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -10" /><path d="M9 5a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v14a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -14" /><path d="M4 20h14" />');
my $icon_edit = build_tabler_icon(30,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M7 7h-1a2 2 0 0 0 -2 2v9a2 2 0 0 0 2 2h9a2 2 0 0 0 2 -2v-1" /><path d="M20.385 6.585a2.1 2.1 0 0 0 -2.97 -2.97l-8.415 8.385v3h3l8.385 -8.415" /><path d="M16 5l3 3" />');
my $icon_trash = build_tabler_icon(30,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0" /><path d="M10 11l0 6" /><path d="M14 11l0 6" /><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12" /><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3" />');
my $icon_image = build_tabler_icon(30,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M15 8h.01" /><path d="M3 6a3 3 0 0 1 3 -3h12a3 3 0 0 1 3 3v12a3 3 0 0 1 -3 3h-12a3 3 0 0 1 -3 -3v-12" /><path d="M3 16l5 -5c.928 -.893 2.072 -.893 3 0l5 5" /><path d="M14 14l1 -1c.928 -.893 2.072 -.893 3 0l3 3" />');

# Smaller FA icons for inline use in tables, 16px
my $icon_link_slash = build_tabler_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M17 22v-2" /><path d="M9 15l6 -6" /><path d="M11 6l.463 -.536a5 5 0 0 1 7.071 7.072l-.534 .464" /><path d="M13 18l-.397 .534a5.068 5.068 0 0 1 -7.127 0a4.972 4.972 0 0 1 0 -7.071l.524 -.463" /><path d="M20 17h2" /><path d="M2 7h2" /><path d="M7 2v2" />');
my $icon_info_small = build_tabler_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0" /><path d="M12 9h.01" /><path d="M11 12h1v4h1" />');
my $icon_repeat_small = build_tabler_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 12v-3a3 3 0 0 1 3 -3h13m-3 -3l3 3l-3 3" /><path d="M20 12v3a3 3 0 0 1 -3 3h-13m3 3l-3 -3l3 -3" />');
my $icon_comment_small = build_tabler_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M8 9h8" /><path d="M8 13h6" /><path d="M18 4a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3h-5l-5 3v-3h-2a3 3 0 0 1 -3 -3v-8a3 3 0 0 1 3 -3h12" />');
my $icon_star_off = build_tabler_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 17.75l-6.172 3.245l1.179 -6.873l-5 -4.867l6.9 -1l3.086 -6.253l3.086 6.253l6.9 1l-5 4.867l1.179 6.873l-6.158 -3.245" />');
my $icon_star_on = build_tabler_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M8.243 7.34l-6.38 .925l-.113 .023a1 1 0 0 0 -.44 1.684l4.622 4.499l-1.09 6.355l-.013 .11a1 1 0 0 0 1.464 .944l5.706 -3l5.693 3l.1 .046a1 1 0 0 0 1.352 -1.1l-1.091 -6.355l4.624 -4.5l.078 -.085a1 1 0 0 0 -.633 -1.62l-6.38 -.926l-2.852 -5.78a1 1 0 0 0 -1.794 0l-2.853 5.78z" />');
my $icon_goto = build_tabler_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v-3.586a1 1 0 0 1 1.707 -.707l6.586 6.586a1 1 0 0 1 0 1.414l-6.586 6.586a1 1 0 0 1 -1.707 -.707v-3.586h-3v-6h3" /><path d="M3 9v6" /><path d="M6 9v6" />');

# Very small FA icons, 
my $icon_rotate_left_small = build_tabler_icon(12,'<path d="M9 14l-4 -4l4 -4" /><path d="M5 10h11a4 4 0 1 1 0 8h-1" />');

# Preflight checks
print STDERR "Loading Taskpony $app_version...\n";
connect_db();                   # Connect to the database
config_load();                  # Load saved config values

print STDERR "\n+-----Welcome to Taskpony! ----------+\n";
print STDERR "|  [X] Install Taskpony              |\n";
print STDERR "|  [ ] Do the thing                  |\n";
print STDERR "|  [ ] Buy milk                      |\n";
print STDERR "+------------------------------------+\n\n";

# Get additional config values.
$list_id = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'active_list' LIMIT 1");
$list_name = single_db_value("SELECT `Title` FROM ListsTb WHERE `id` = ?", $list_id) || 'Unknown List';

####################################
# Start main loop

my $static_dir = catdir($FindBin::Bin);
my $running_in_docker = 0;  # 1 if in docker, 0 if not
if (-f '/.dockerenv') { $running_in_docker = 1;}  # Test for this magical file that docker created.

my $app = sub {
    my $env = shift; 
    my $req = Plack::Request->new($env);
    my $res = Plack::Response->new(200);

    if (not $dbh->ping) { connect_db(); }      # Reconnect to DB if needed

    # Global modifiers
    $show_completed = $req->param('sc') // 0;   # If ?sc=1 we want to show completed tasks. 
    $list_id = $req->param('lid') || 0;         # Select list from ?lid= param, or 0 if not set
    update_db_mtime();                          # Ensure we have the latest mtime cached
    calculate_stats();                          # Update stats hashref if needed

    # If no list lid specified, get the active list from ConfigTb to provide consistency to user
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
        $list_name = single_db_value("SELECT `Title` FROM ListsTb WHERE `id` = ?", $list_id) || 'Unknown List';
        }

    ###############################################
    # favicon handling before header()
    if ($req->path eq "/favicon.ico") {     # Redirect to ./static/favicon.ico
        $res->redirect('./static/favicon.ico');
        return $res->finalize;
        } # End /favicon.ico

    ###############################################
    # /api/dbstate check - returns simple JSON with last mtime of the database
    if ($req->path eq "/api/dbstate") {
        update_db_mtime();  # Ensure we have the latest mtime cached
        debug("API DB State requested, returning mtime: $db_mtime");
        $res->header('Content-Type' => 'text/plain');
        $res->header('Cache-Control' => 'no-cache, no-store');
        $res->body($db_mtime);
        return $res->finalize;
        } # End /api/dbstate

    ###############################################
    # Start building page
    my $html = header();

    ###############################################
    # Step through named paths
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

            print STDERR "INFO: Task $task_id marked as complete\n";
            $stats->{tasks_completed_today} += 1; 
            add_alert("Task #$task_id marked as completed. $stats->{tasks_completed_today} tasks completed today!");
            }

        # Always redirect
        $res->redirect('/');
        return $res->finalize;
    } # End /complete

    ###############################################
    # Set TASK nn as Status 1 in TasksTb (Active)
    if ($req->path eq "/ust") {
        if ($req->method && uc($req->method) eq 'GET') {
            my $task_id = $req->param('task_id') // 0;
            
            if ($task_id > 0) {
                my $sth = $dbh->prepare('UPDATE TasksTb SET Status = 1, AddedDate = CURRENT_TIMESTAMP, CompletedDate = NULL WHERE id = ?');
                eval { $sth->execute($task_id); 1 } or print STDERR "Update failed: $@";
                print STDERR "INFO: Task $task_id marked as active again\n";
                add_alert("Task #$task_id re-activated.");
                $stats->{tasks_completed_today} -= 1; 
            }
        }
        $res->redirect('/?sc=1'); # Redirect back to completed tasks view and show completed tasks, as we probably came from there
        return $res->finalize;
        } # End /ust

    ###############################################
    # Set LIST nn as UnDeleted (Active)
    if ($req->path eq "/list_undelete") {
        if ($req->method && uc($req->method) eq 'GET') {
            my $lid = $req->param('id');
            if ($lid > 1) { # Don't allow undeleting "All Tasks Lists"
                print STDERR "INFO: Undeleting list id $lid\n";
                my $sth = $dbh->prepare('UPDATE ListsTb SET DeletedDate = NULL WHERE id = ? LIMIT 1');
                eval { $sth->execute($lid); 1 } or print STDERR "WARN: List undelete failed: $@";
                add_alert("List #$lid restored.");
                }
            }
        $res->redirect('/lists'); # Redirect back to lists view
        return $res->finalize;
        } # End /list_undelete

    ###############################################
    # Set LIST nn as Deleted
    if ($req->path eq "/list_delete") {
        if ($req->method && uc($req->method) eq 'GET') {
            my $lid = $req->param('id');
            if ($lid > 1) { # Don't allow deleting "All Tasks Lists"
                print STDERR "INFO:Permanently deleting list id $lid\n";
                my $sth = $dbh->prepare('DELETE FROM ListsTb WHERE id = ? LIMIT 1');
                eval { $sth->execute($lid); 1 } or print STDERR "WARN: List delete failed: $@";
                add_alert("List #$lid deleted.");
                }
            }
        $res->redirect('/lists'); # Redirect back to lists view
        return $res->finalize;
        } # End /list_delete

    ###############################################
    # Handle setting a list as default
    if ($req->path eq "/set_default_list") {
        if ($req->method && uc($req->method) eq 'GET') {
            my $lid = $req->param('id');
            if ($lid > 1) { # Don't allow setting "All Tasks Lists" as default
                print STDERR "Setting list $lid as default list.\n";
                single_db_value('UPDATE ListsTb SET IsDefault = 0 WHERE IsDefault = 1'); # Clear current default
                my $sth = $dbh->prepare('UPDATE ListsTb SET IsDefault = 1 WHERE id = ?');
                eval { $sth->execute($lid); 1 } or print STDERR "WARN: Set default lid update failed: $@";                
                add_alert("List #$lid set as default.");
                }
            }
        $res->redirect('/lists'); # Redirect back to completed tasks view and show completed tasks, as we probably came from there
        return $res->finalize;
        } # End /set_default_list

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

            $stats->{tasks_added_today} += 1; 
            add_alert("Task '$title' added.  That's $stats->{tasks_added_today} new tasks today!");
            $res->redirect('/');
            return $res->finalize;
            } # End /add form submission handling

        # If page, show the add-task form
        my $html = header();
        $html .= qq~
            <div class="container py-2">
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
        } # End /add

    ###############################################
    # Handle editing a task
    if ($req->path eq "/edittask") {
        my $task_id = $req->param('id') // 0;

        # If POST, update the task in DB and redirect
        if ($req->method && uc($req->method) eq 'POST') {
            my $title = sanitize($req->param('Title') // '');
            my $desc  = sanitize($req->param('Description') // '');
            my $list_id = $req->param('ListId') // 0;
            my $is_recurring = sanitize($req->param('IsRecurring') // '');            
            my $recurring_interval = sanitize($req->param('RecurringIntervalDay') // '');
            # Validate recurring interval
            if ($recurring_interval !~ /^\d+$/) { 
                print STDERR "WARN: Task $task_id recurring_interval is not a number. Resetting to 1.\n";
                $recurring_interval = 1;
                }
            if ($recurring_interval < 1) {
                print STDERR "WARN: Task $task_id recurring_interval is below minimum (1). Resetting to 1.\n";
                $recurring_interval = 1;
                }
            if ($recurring_interval > 365) {
                print STDERR "WARN: Task $task_id recurring_interval is above maximum (365). Resetting to 365.\n";
                $recurring_interval = 365;
                }

            if (length $title && $task_id > 0 && $list_id > 1) {
                my $sth = $dbh->prepare(
                    'UPDATE TasksTb SET Title = ?, Description = ?, ListId = ?, isRecurring = ?, RecurringIntervalDay = ? WHERE id = ?'
                    );
                eval { $sth->execute($title, $desc, $list_id, $is_recurring, $recurring_interval, $task_id); 1 } or print STDERR "Task update failed: $@";
                debug("Task $task_id updated");
                }

            add_alert("Task $task_id updated.");
            $res->redirect('/');
            return $res->finalize;
            } # End /edittask form submission handling

        # Display edit form
        if ($task_id > 0) {
            my $sth = $dbh->prepare('SELECT * FROM TasksTb WHERE id = ?');
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

                $html .= start_card("Edit Task #$task_id - $task_status", $icon_edit, 0);

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




                                <div class="border p-3 mb-3">
                                    <div class="d-flex flex-column flex-md-row gap-3">
                                         
                                        <div class="border p-3 flex-fill ">
                                            
                                            <div class="form-check form-switch m-0">
                                            Repeat this task after completion
                                                <input class="form-check-input" type="checkbox" name="IsRecurring" id="autoUpdateToggle"
                                            ~;

                                            # Precheck the box if IsRecurring is already 'on'

                                            if ($task->{'IsRecurring'} eq 'on') { $html .= " checked "; } 
                                            
                                            $html .= qq~>
                                            <span data-bs-toggle="tooltip" data-bs-placement="auto" title="When you complete this task, it will automatically become active again after the selected number of days.">
                                                $icon_info_small
                                            </span>
                                            </div>
                                        </div>

                                        <div class="border p-3 flex-fill ">
                                            
                                            <div class="d-flex align-items-center gap-2">
                                                Repeat every
                                                    <input type="number" class="form-control form-control-sm" style="width: 80px;"
                                                        name="RecurringIntervalDay" min="1" max="365" value="$task->{RecurringIntervalDay}">
                                                    <span>
                                                        days
                                                    </span>
                                                    <span data-bs-toggle="tooltip" data-bs-placement="auto" title="How many days after completion should this task re-activate? Range 1-365">
                                                        $icon_info_small
                                                    </span>
                                            </div>
                                        </div>
                                    </div>
                                </div>



                                <div class="col-12">
                                <label class="form-label">List</label>
                                $list_dropdown
                                </div>

                                <div class="col-12">
                                <div class="d-flex flex-wrap gap-2">
                                <button class="btn btn-primary me-auto" type="submit">Save Task</button>
                                <a class="btn btn-secondary" href="/">Cancel</a>

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
                                    <a class="btn btn-danger" href="/?delete_task=$task_id">Delete Task</a>
                                </div>

                               <br/>
                                <p class="text-secondary">
                                    This task was created $task->{AddedDate}
                                    ~;
                                    if ($task->{CompletedDate}) {
                                        $html .= qq~and completed $task->{CompletedDate}~;
                                        }
                                    $html .= qq~
                                </p>

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
        } # End /edittask

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
                $stats->{total_lists} += 1;
                $stats->{total_active_lists} += 1;
                } elsif ($action eq 'edit' && $list_id > 1 && length $title) {
                my $sth = $dbh->prepare(
                    'UPDATE ListsTb SET Title = ?, Description = ? WHERE id = ?'
                    );

                eval { $sth->execute($title, $desc, $list_id); 1 } or print STDERR "Update failed: $@";
                add_alert("List updated.");
                } elsif ($action eq 'delete_orphan' && $list_id > 1) {
                # Delete list, leave tasks orphaned (no list assignment)
                my $sth = $dbh->prepare(
                    'UPDATE ListsTb SET DeletedDate = CURRENT_TIMESTAMP WHERE id = ?'
                    );
                eval { $sth->execute($list_id); 1 } or print STDERR "Delete failed: $@";
                add_alert("List deleted. Active tasks have been orphaned.");
                $stats->{total_lists} -= 1;
                $stats->{total_active_lists} -= 1;
                
                # Check if deleted list was the active list, if so switch to default
                my $current_active = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'active_list' LIMIT 1");
                if ($current_active == $list_id) {
                    my $default_list = single_db_value("SELECT `id` FROM ListsTb WHERE IsDefault = 1 AND DeletedDate IS NULL LIMIT 1");
                    if ($default_list) {
                        $dbh->do("INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", undef, 'active_list', $default_list, $default_list);
                    }
                }
                } elsif ($action eq 'delete_complete' && $list_id > 1) {
                # Mark all tasks in this list as completed, then delete list
                my $update_sth = $dbh->prepare(
                    'UPDATE TasksTb SET Status = 2, CompletedDate = CURRENT_TIMESTAMP WHERE ListId = ? AND Status = 1'
                    );
                eval { $update_sth->execute($list_id); 1 } or print STDERR "Task completion failed: $@";
                
                my $delete_sth = $dbh->prepare(
                    'UPDATE ListsTb SET DeletedDate = CURRENT_TIMESTAMP WHERE id = ?'
                    );
                eval { $delete_sth->execute($list_id); 1 } or print STDERR "Delete failed: $@";
                add_alert("List deleted and all active tasks marked as completed.");
                $stats->{total_lists} -= 1;
                $stats->{total_active_lists} -= 1;
                
                # Check if deleted list was the active list, if so switch to default
                my $current_active = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'active_list' LIMIT 1");
                if ($current_active == $list_id) {
                    my $default_list = single_db_value("SELECT `id` FROM ListsTb WHERE IsDefault = 1 AND DeletedDate IS NULL LIMIT 1");
                    if ($default_list) {
                        $dbh->do("INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", undef, 'active_list', $default_list, $default_list);
                    }
                }
                } elsif ($action eq 'delete_move' && $list_id > 1) {
                # Move all active tasks to another list, then delete the list
                my $target_list_id = $req->param('target_list_id') // 0;
                
                if ($target_list_id > 1 && $target_list_id != $list_id) {
                    my $move_sth = $dbh->prepare(
                        'UPDATE TasksTb SET ListId = ? WHERE ListId = ? AND Status = 1'
                        );
                    eval { $move_sth->execute($target_list_id, $list_id); 1 } or print STDERR "Task move failed: $@";
                    
                    my $delete_sth = $dbh->prepare(
                        'UPDATE ListsTb SET DeletedDate = CURRENT_TIMESTAMP WHERE id = ?'
                        );
                    eval { $delete_sth->execute($list_id); 1 } or print STDERR "Delete failed: $@";
                    
                    add_alert("List deleted and active tasks moved to target list.");
                    $stats->{total_lists} -= 1;
                    $stats->{total_active_lists} -= 1;
                    
                    # Check if deleted list was the active list, if so switch to default
                    my $current_active = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'active_list' LIMIT 1");
                    if ($current_active == $list_id) {
                        my $default_list = single_db_value("SELECT `id` FROM ListsTb WHERE IsDefault = 1 AND DeletedDate IS NULL LIMIT 1");
                        if ($default_list) {
                            $dbh->do("INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", undef, 'active_list', $default_list, $default_list);
                        }
                    }
                } else {
                    add_alert("Invalid target list selected.");
                }
                } elsif ($action eq 'delete' && $list_id > 1) {
                # Legacy delete (orphan) - for backwards compatibility
                my $sth = $dbh->prepare(
                    'UPDATE ListsTb SET DeletedDate = CURRENT_TIMESTAMP WHERE id = ?'
                    );

                eval { $sth->execute($list_id); 1 } or print STDERR "Delete failed: $@";
                add_alert("List deleted.");
                $stats->{total_lists} -= 1;
                $stats->{total_active_lists} -= 1;
                
                # Check if deleted list was the active list, if so switch to default
                my $current_active = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'active_list' LIMIT 1");
                if ($current_active == $list_id) {
                    my $default_list = single_db_value("SELECT `id` FROM ListsTb WHERE IsDefault = 1 AND DeletedDate IS NULL LIMIT 1");
                    if ($default_list) {
                        $dbh->do("INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", undef, 'active_list', $default_list, $default_list);
                    }
                }
                }

            $res->redirect('/lists');
            return $res->finalize;
            } # End /lists form submission handling

        # Page - Display List of Lists
        $html .= start_card('Lists Management', $icon_list, 0);
        $html .= qq~  
                            <div class="table-responsive">
                            <table class="table table-dark table-striped">
                                <thead>
                                    <tr>
                                        <th>List</th> 
                                        <th>Description</th>
                                        <th>Active Tasks</th>
                                        <th>Completed Tasks</th>
                                        <th><span class="badge bg-secondary text-white" data-bs-toggle="tooltip" data-bs-placement="auto" title="The default list appears at the top of the list picklist">Default</span></th>
                                        <th>Actions</th>
                                    </tr>
                                </thead>
                            <tbody>
        ~;

        # Add "All Tasks Lists" row
        my $all_active = single_db_value('SELECT COUNT(*) FROM TasksTb WHERE Status = 1') // 0;
        my $all_completed = single_db_value('SELECT COUNT(*) FROM TasksTb WHERE Status = 2') // 0;
        
        $html .= qq~
                                <tr>
                                    <td><strong><a href="/?lid=1"> <span class="badge bg-secondary text-white">All Tasks</span></a></strong></td>
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
                <span class="badge bg-secondary text-white" data-bs-toggle="tooltip" data-bs-placement="auto" title="Make this the default list">                
                    $icon_star_off
                </span>
                </a>
                ~;

            if ($list->{'IsDefault'} == 1) {
                $is_default_str = qq~
                    <span class="badge bg-success" data-bs-toggle="tooltip" data-bs-placement="auto" title="This is the default list">
                        $icon_star_on
                    </span>~;
                }

            $html .= qq~
                                <tr>
                                    <td>
                                        <strong>
                                            <span data-bs-toggle="tooltip" data-bs-placement="auto" title="Edit List Details"><a class="text-white text-decoration-none" href="/editlist?id=$list->{'id'}">
                                                $title
                                            </a>
                                            </span>
                                        </strong>
                                    </td>
                                    <td>
                                        <a href="/?lid=$list->{'id'}" class="btn-sm text-white text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Jump to $title">
                                          $icon_goto &nbsp;
                                        </a>
                                        $desc
                                    </td>
                                    <td>$active_count</td>
                                    <td>$completed_count</td>
                                    <td>$is_default_str</td>
                                    <td class="text-end">
                                        <button type="button" class="btn btn-sm btn-danger" data-bs-toggle="modal" data-bs-placement="auto" data-bs-target="#deleteListModal" data-list-id="$list->{'id'}" data-list-title="$title" data-active-tasks="$active_count">
                                            Delete
                                        </button>
                                    </td>
                                </tr>
                ~;
            } # End lists loop

        $html .= qq~
                            </tbody>
                        </table>
                            </div>
                    </div>
                </div>
                ~;

        # Build the list of available lists for moving tasks as JSON
        my $move_lists_sth = $dbh->prepare('SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL AND id > 1 ORDER BY Title ASC');
        $move_lists_sth->execute();
        my @move_lists;
        while (my $ml = $move_lists_sth->fetchrow_hashref()) {
            push @move_lists, { id => $ml->{'id'}, title => html_escape($ml->{'Title'}) };
        }
        
        # Convert to JSON for JavaScript use
        my $move_lists_json = '[';
        foreach my $i (0 .. $#move_lists) {
            my $ml = $move_lists[$i];
            $move_lists_json .= qq~{"id":"$ml->{'id'}","title":"$ml->{'title'}"}~;
            $move_lists_json .= ',' if $i < $#move_lists;
        }
        $move_lists_json .= ']';

        # Add delete list modal
        $html .= qq~
        <!-- Delete List Modal -->
        <div class="modal fade" id="deleteListModal" tabindex="-1" aria-labelledby="deleteListModalLabel" aria-hidden="true">
          <div class="modal-dialog modal-dialog-centered">
            <div class="modal-content bg-dark text-white">
              <div class="modal-header">
                <h5 class="modal-title" id="deleteListModalLabel">Delete List</h5>
                <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
              </div>
              <div class="modal-body">
                <p>How would you like to handle any existing tasks in <strong id="modalListTitle"></strong>?</p>
                <form id="deleteListForm" method="post" action="/lists">
                  <input type="hidden" name="list_id" id="modalListId" value="">
                  <div class="mb-3">
                    <div class="form-check">
                      <input class="form-check-input" type="radio" name="delete_option" id="deleteOrphan" value="delete_orphan" checked>
                      <label class="form-check-label" for="deleteOrphan">
                        Delete List and orphan any active tasks? <br><i>(Tasks will still appear in the 'All Tasks List')</i>
                      </label>
                    </div>
                    <div class="form-check">
                      <input class="form-check-input" type="radio" name="delete_option" id="deleteComplete" value="delete_complete">
                      <label class="form-check-label" for="deleteComplete">
                        Delete List and mark any tasks as Completed?
                      </label>
                    </div>
                    <div class="form-check">
                      <input class="form-check-input" type="radio" name="delete_option" id="deleteMove" value="delete_move">
                      <label class="form-check-label" for="deleteMove">
                        Delete List and move any active tasks to another list?
                      </label>
                    </div>
                    <div id="moveListContainer" class="mt-2" style="display:none;">
                      <label for="targetListId" class="form-label">Move tasks to:</label>
                      <select class="form-select bg-dark text-white border-secondary" id="targetListId" name="target_list_id">
                      </select>
                    </div>
                  </div>
                </form>
              </div>
              <div class="modal-footer">
                <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
                <button type="button" class="btn btn-danger" id="confirmDeleteBtn">Delete List</button>
              </div>
            </div>
          </div>
        </div>

        <script>
        var allLists = $move_lists_json;
        
        document.addEventListener('DOMContentLoaded', function() {
          // Handle modal opening - populate with list details and options
          var deleteListModal = document.getElementById('deleteListModal');
          deleteListModal.addEventListener('show.bs.modal', function (event) {
            var button = event.relatedTarget;
            var listId = button.getAttribute('data-list-id');
            var listTitle = button.getAttribute('data-list-title');
            var activeTasksCount = button.getAttribute('data-active-tasks');
            
            document.getElementById('modalListId').value = listId;
            document.getElementById('modalListTitle').innerHTML = listTitle + ' <i>(' + activeTasksCount + ' active tasks)</i>';
            
            // Populate target list dropdown, excluding the list being deleted
            var selectElement = document.getElementById('targetListId');
            selectElement.innerHTML = '';
            allLists.forEach(function(list) {
              if (list.id !== listId) {
                var option = document.createElement('option');
                option.value = list.id;
                option.textContent = list.title;
                selectElement.appendChild(option);
              }
            });
          });

          // Handle radio button changes for move option visibility
          var deleteOrphan = document.getElementById('deleteOrphan');
          var deleteComplete = document.getElementById('deleteComplete');
          var deleteMove = document.getElementById('deleteMove');
          var moveListContainer = document.getElementById('moveListContainer');

          [deleteOrphan, deleteComplete, deleteMove].forEach(function(radio) {
            radio.addEventListener('change', function() {
              if (deleteMove.checked) {
                moveListContainer.style.display = 'block';
                document.getElementById('targetListId').focus();
              } else {
                moveListContainer.style.display = 'none';
              }
            });
          });

          // Handle delete button click
          document.getElementById('confirmDeleteBtn').addEventListener('click', function() {
            var selectedOption = document.querySelector('input[name="delete_option"]:checked').value;
            
            // Validate that move option has a target list selected
            if (selectedOption === 'delete_move') {
              var targetListId = document.getElementById('targetListId').value;
              var currentListId = document.getElementById('modalListId').value;
              if (!targetListId) {
                alert('Please select a target list for moving tasks.');
                return;
              }
              if (targetListId == currentListId) {
                alert('Cannot move tasks to the same list. Please select a different list.');
                return;
              }
            }

            // Add action to form and submit
            var form = document.getElementById('deleteListForm');
            var actionInput = document.createElement('input');
            actionInput.type = 'hidden';
            actionInput.name = 'action';
            actionInput.value = selectedOption;
            form.appendChild(actionInput);
            form.submit();
          });
        });
        </script>
        ~;

        # Add New List form
        $html .= start_mini_card('Add New List', $icon_list);
        $html .= qq~
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
                                ~;

        $html .= end_card();


        # Deleted Lists Card and Table
        $html .= start_mini_card('Deleted Lists', $icon_trash, 0);

        $html .= qq~  
                            <div class="table-responsive">
                            <table class="table table-dark table-striped">
                                <thead>
                                    <tr>
                                        <th>List</th> 
                                        <th>Deleted Date</th>
                                        <th>Action</th>
                                    </tr>
                                </thead>
                            <tbody>
        ~;
        my $deleted_list_sth = $dbh->prepare(
            'SELECT id, Title, DeletedDate FROM ListsTb WHERE DeletedDate IS NOT NULL AND id != 1 ORDER BY DeletedDate DESC'
            );  # Don't select ListsTb.id=1, "All" 
        $deleted_list_sth->execute();   
        # Step through deleted lists
        while (my $a = $deleted_list_sth->fetchrow_hashref()) {
            my $title = html_escape($a->{'Title'});
            my $deleted_date = $a->{'DeletedDate'};            
            
            $html .= qq~
                                <tr>
                                    <td>
                                        <strong>
                                            $title
                                        </strong>
                                    </td>
                                    <td>
                                        $deleted_date
                                    </td>
                                    <td class="text-end">
                                            <a href="/list_undelete?id=$a->{'id'}" class="btn btn-sm btn-success" data-bs-toggle="tooltip" data-bs-placement="auto" title="Return this List to active status">Undelete</a>
                                            &nbsp;&nbsp;
                                            <a href="/list_delete?id=$a->{'id'}" class="btn btn-sm btn-danger" data-bs-toggle="tooltip" data-bs-placement="auto" title="Permanently delete this list from the Database. Associated Tasks will be orphaned.">Permanently Delete</a> 
                                    

                                    </td>
                                </tr>
                ~;
            } # End deleted lists loop
        $html .= qq~
                            </tbody>
                        </table>
                            </div>
                ~;

        $html .= end_card();



        $html .= footer();
        $res->body($html);
        return $res->finalize;
        } # End /lists

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
                } # End /editlist form submission handling

            # If GET, show the edit-list form
            if ($list_id > 1) {
                my $sth = $dbh->prepare('SELECT id, Title, Description FROM ListsTb WHERE id = ?');
                $sth->execute($list_id);
                my $list= $sth->fetchrow_hashref();

                if ($list) {
                    my $html = header();
                    $html .= start_card("Edit List", $icon_list, 0);
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
            } # End /editlist

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
                            # Special handling for checkboxes which will return void if not set
                            if ($key =~ 'cfg_include_datatable_|cfg_export_all_cols|cfg_show_dates|cfg_version_check|cfg_include_datatable_search|cfg_background_image|cfg_show_lists') {
                                $new_val = 'off';
                                debug("Belay that, this is a checkbox, set it to off");
                                } else {
                                $new_val = $config->{$key}; # No value supplied, use existing
                                }
                            }

                        # Set current local config value
                        $config->{$key} = $new_val;

                        } # End keys lookup
                    # Save config to db
                    save_config();
                    } 
                
                add_alert("Configuration saved");
                $res->redirect('/');
                return $res->finalize;
                } # End /config form submission handling

        ###############################################
        # Show the Settings page

        my $html .= header();

        $html .= start_card("Settings", $icon_gear, 0);
        $html .= qq~
            <form method="post" action="/config" style="display:inline;">
            <input type="hidden" name="save_config" value="true">

            <div class="container">~;

            # Row One
            $html .= qq~
                <div class="row">

                    <!-- COLUMN ONE ############################################### -->                    
                    <div class="col">
                        <div class="card bg-dark text-white" style="width: 18rem;">
                            <h5 class="card-title">Task List Settings</h5>
                        </div>

                    <div class="card-body">
                    ~;

                    # Draw Row 1 - Visual Settings
                    $html .= config_show_option('cfg_include_datatable_search','Display Filter Box','Show the filter box at the top right of the Tasks table','check',0,0);
                    $html .= config_show_option('cfg_include_datatable_buttons','Display export buttons','Display the export buttons at the end of the Tasks list - Copy, CSV, PDF, etc','check',0,0); 
                    $html .= config_show_option('cfg_show_dates_lists','Show Dates and Lists','Switch between showing just the Task Titles and also including the Dates and Lists columns','check',0,0);

                    $html .= config_show_option('cfg_task_pagination_length','Number of Tasks to show on each page','How many tasks to show on each page before paginating. Range 3-1000','number',3,1000);                     
                    $html .= config_show_option('cfg_description_short_length','Max length of popup Task descriptions','Maximum characters to display of the popup Task description in the Task list before truncating it. Range 3-1000','number',3,1000);
                    $html .= config_show_option('cfg_list_short_length','Max length of List name in Tasks list','Maximum characters to display of the List title in the rightmost column before truncating it in the Tasks list. Range 1-100','number',1,100);

            $html .= qq~
                </div>
            </div>
            ~;

            # Row Two
            $html .= qq~
                <div class="col">
                    <div class="card bg-dark text-white" style="width: 18rem;">
                        <h5 class="card-title">Other Settings</h5>
                    </div>

                <div class="card-body">
                ~;
               
                $html .= config_show_option('cfg_export_all_cols','Export date and list',"When using the export buttons, $app_title will normally just export the Task name. Enable this to include the date and list for each task",'check',0,0);
                $html .= config_show_option('cfg_backup_number_to_keep','Number of daily backups to keep',"Each day, $app_title makes a backup of its database. This setting controls how many days worth of backups to keep. Older backups will be deleted automatically. Range 1-100",'number',1,100);
                $html .= config_show_option('cfg_version_check','Check for new versions','If checked, Taskpony will occasionally check for new versions of itself and show a small badge in the footer if one is available','check',0,0);
                $html .= config_show_option('cfg_header_colour','Highlight Colour','Select colour for panel header backgrounds and highlights','colour',0,0);
                $html .= config_show_option('cfg_background_image','Enable background image','If checked, an JPG can be uploaded through this form below and will be used as a background','check',0,0);


            $html .= qq~

            <br/
            >
            <div class="text-end">
                <button class="btn btn-primary">Save Settings</button>  
            </div>

            </div>

            ~;

            # End the main form
            $html .= qq~
                    </div>
                </div>
            </form>
            ~;

            $html .= end_card();

            $html .= start_card('Background Image Upload', $icon_image, 0);

            # Start a second form for the background image upload
            $html .= qq~
            <form method="post" action="/background_set" enctype="multipart/form-data">
                <div class="d-flex flex-wrap align-items-center justify-content-between p-3 bg-dark text-white rounded gap-3">
                    <label for="background" class="form-label mb-0 flex-grow-1"  
                        data-bs-toggle="tooltip" data-bs-placement="auto"
                        title="If enabled above, Taskpony can show a background image on the page">
                        Change the background image
                    </label>
                    
                    <div class="d-flex align-items-center gap-2">
                        <input
                            class="form-control"
                            style="width: 200px;" 
                            type="file"
                            id="background"
                            name="background"
                            accept="image/jpeg"
                            required>
                        <button type="submit" class="btn btn-success text-nowrap">
                            Go
                        </button>
                    </div>
                </div>

                <div class="form-text mt-1">
                    Upload a JPG to replace the current background image.
                </div>
            </form>            
            ~;

        $html .= end_card();

        $html .= footer();
        $res->body($html);
        return $res->finalize;
        } # End /config

        ###############################################
        # Stats page - show calculated statistics
        if ($req->path eq "/stats") {
            my $html = header();
            $html .= start_card('Statistics', $icon_chart, 0);

            $html .= qq~
                <div class="table-responsive">
                <table class="table table-dark table-striped">
                    <thead>
                        <tr><th>Statistic</th><th>Value</th></tr>
                    </thead>
                    <tbody>
            ~;

            $html .= qq~
                        <tr class="table-borderless">
                        <td class="fw-semibold">Tasks</td>
                        <td>
                            <div class="d-flex flex-wrap gap-2">
                            <span class="badge bg-primary">Total: $stats->{'total_tasks'}</span>
                            <span class="badge bg-success">Active: $stats->{'active_tasks'}</span>
                            <span class="badge bg-secondary">Completed: $stats->{'completed_tasks'}</span>
                            <span class="badge bg-info">Repeating: $stats->{'repeating_tasks'}</span>
                            </div>
                        </td>
                        </tr>

                        <tr>
                        <td class="fw-semibold pt-3">Today</td>
                        <td class="pt-3">
                            <div class="d-flex flex-wrap gap-2">
                            <span class="badge bg-success">Added: $stats->{'tasks_added_today'}</span>
                            <span class="badge bg-secondary">Completed: $stats->{'tasks_completed_today'}</span>
                            </div>
                        </td>
                        </tr>

                        <tr>
                        <td class="fw-semibold pt-3">Past Week</td>
                        <td class="pt-3">
                            <div class="d-flex flex-wrap gap-2">
                            <span class="badge bg-success">Added: $stats->{'tasks_added_past_week'}</span>
                            <span class="badge bg-secondary">Completed: $stats->{'tasks_completed_past_week'}</span>
                            </div>
                        </td>
                        </tr>

                        <tr class="text-muted">
                        <td class="pt-2">Past Month</td>
                        <td class="pt-2">
                            <div class="d-flex flex-wrap gap-2">
                            <span class="badge bg-success">Added: $stats->{'tasks_added_past_month'}</span>
                            <span class="badge bg-secondary">Completed: $stats->{'tasks_completed_past_month'}</span>
                            </div>
                        </td>
                        </tr>

                        <tr class="text-muted">
                        <td>Past Year</td>
                        <td>
                            <div class="d-flex flex-wrap gap-2">
                            <span class="badge bg-success">Added: $stats->{'tasks_added_past_year'}</span>
                            <span class="badge bg-secondary">Completed: $stats->{'tasks_completed_past_year'}</span>
                            </div>
                        </td>
                        </tr>

                        <tr>
                        <td class="fw-semibold pt-3">Lists</td>
                        <td class="pt-3">
                            <div class="d-flex flex-wrap gap-2">
                            <span class="badge bg-primary">Total Lists: $stats->{'total_lists'}</span>
                            <span class="badge bg-success">Currently Active: $stats->{'total_active_lists'}</span>
                            </div>
                        </td>
                        </tr>
                    </tbody>
                </table>

                <ul>
                    <li>
                        <span class="pt-3 small text-white-50">
                            First task created: 
                                <strong class="text-white">$stats->{'stats_first_task_created'}</strong>
                                <span class="ms-2">($stats->{'stats_first_task_created_daysago'} days ago)</span>
                        </span>
                    </li>
                    <li>
                        <span class="pt-3 small text-white-50">
                            Database schema version (Actual / Required): 
                                <strong class="text-white">$config->{'database_schema_version'} / $database_schema_version</strong>
                        </span>
                    </li>
                    <li>
                        <span class="pt-3 small text-white-50">~;
                            if ($running_in_docker == 1) {
                                $html .= qq~Running inside Docker ~;
                                } else {
                                $html .= qq~Running on host as a native service ~;
                                }
                            $html .= qq~ 
                        </span>
                    </li>
                </ul>
            </div>
            ~;

            $html .= end_card();
            $html .= footer();
            $res->body($html);
            return $res->finalize;
            } # End /stats

    ###############################################
    # End named paths

    ###############################################
    # /background_set  = Receive new background image upload
    if ($req->method eq 'POST' && $req->path eq '/background_set') {

        my $upload = $req->upload('background') or return [400, [], ['No file uploaded']];

        if ($upload->size > 5 * 1024 * 1024) {
            print STDERR "Uploaded background is too large\n";
            add_alert("Uploaded image was too large. Size limited to 5MB");
            return [302, [ Location => '/config' ], []];
            }

        my $type = $upload->content_type;
        my $ext =
            $type eq 'image/jpeg' ? 'jpg' :
            return [400, [], ['Unsupported type']];

        my $src = $upload->path or return [500, [], ['Upload has no temp path']];

        my $tmp = "$bg_path.tmp";  # Write out a temporary file as bg pic may be slow to upload

        copy($src, $tmp) or return [500, [], ["Copy failed: $!"]];

        rename $tmp, $bg_path or return [500, [], ["Rename failed: $!"]];

        add_alert("Background image updated");
        return [302, [ Location => '/config' ], []];
        } # End /background_set

    ###############################################
    # /?delete_task=nn - Delete task nn (Actually delete, not just set as completed)
    my $delete_task = $req->param('delete_task') // 0;        
    if ($delete_task > 0) {
        my $sth = $dbh->prepare('DELETE FROM TasksTb WHERE id = ?');
        eval { $sth->execute($delete_task); 1 } or print STDERR "WARN: Delete TasksTb.id=$delete_task failed: $@";
        add_alert("Task #$delete_task deleted.");
        $res->redirect('/'); # Redirect back to default page
        return $res->finalize;
        } # End /?delete_task=nn

    ###############################################
    # Default home/tasklist page - If no other paths have taken the request then land here, list tasks and the quickadd form

    # Set default titlebar to be the quick add form for the selected list
    my $titlebar = qq~</h2>
                        <form method="post" action="/add" class="d-flex align-items-center gap-2 m-0">
                            <input name="Title" autofocus class="form-control" required maxlength="200" placeholder="Add a new task to '$list_name' " />
                            <button class="btn btn-primary" type="submit">Add</button>
                        </form>
                        <h2>
                    ~;

    # If showing all lists, change titlebar to show what is being displayed instead of the form
    if ($list_id == 1) {
        if ($show_completed == 1) {
            $titlebar = "Showing completed tasks from all lists";
            } else {
            $titlebar = "Showing active tasks from all lists";
            }
        } # End if ($list_id == 1)

    $html .= start_card($titlebar,'',1);

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

    $html .= footer();
    $res->body($html);
    return $res->finalize;
    };   # End main loop, pages and paths handling

builder { # Enable Static middleware for specific paths, including favicon.ico, css and js  Launches main loop on first run.    
    enable 'Plack::Middleware::Static', 
        path => qr{^/static/},
        root => $static_dir;
    $app;
    };

###############################################
# Functions
###############################################

###############################################
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
    }  # End connect_db()

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
            ('active_list', '2')
            ;
        ~) or print STDERR "WARN: Failed to populate ConfigTb: " . $dbh->errstr;

    # Save initial config values from local config hash
    save_config();

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
        (1, 'All Tasks', 'View tasks from all lists', 0),
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
        ('Sample Task 3', 'Install Taskpony. Hey, you did this, you can tick it off!', 2);
        ~) or print STDERR "WARN: Failed to populate TasksTb: " . $dbh->errstr;

    print STDERR "Database initialisation complete, schema version 1.\n";

    } # End initialise_database()

###############################################
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

            # List of queries required to upgrade from v.1 to v.2
            my @db_upgrade_steps_1_to_2 = (
                "UPDATE ListsTb SET Title = 'All Tasks' WHERE Title = 'All Lists';",                # Change name of 'All Lists' to 'All Tasks'
                "UPDATE ConfigTb SET `value` = '2' WHERE `key` = 'database_schema_version';",       # Update version number in ConfigTb
                "ALTER TABLE TasksTb ADD COLUMN IsRecurring TEXT DEFAULT 'off';",                   # New column to indicate whether task is recurring
                "ALTER TABLE TasksTb ADD COLUMN RecurringIntervalDay INTEGER DEFAULT 1;",           # New column to indicate recurring interval in days
                );

            foreach my $upgrade_query (@db_upgrade_steps_1_to_2) {
                print STDERR "Applying DB upgrade step: $upgrade_query\n";
                eval { $dbh->do($upgrade_query); 1 } or print STDERR "WARN: Failed to apply DB upgrade step: $upgrade_query : " . $dbh->errstr;
                }

            # Re-fetch current DB version after upgrade steps to ensure it's updated
            $current_db_version = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'database_schema_version' LIMIT 1") || 1;

            if ($current_db_version != 2) {
                print STDERR "WARN: Database schema upgrade to version 2 did not complete successfully. Current version is still $current_db_version.\n";
                } else {
                print STDERR "INFO: Database schema successfully upgraded to version 2.\n";
                }
            } # End db v.1 to v.2 upgrade

        # !! Add v.2 to v.3 upgrade steps here !!

        } else {
        print STDERR "Preflight checks: Database schema version is up to date at version $current_db_version. Required version is $database_schema_version. We're good.\n";
        }
    } # End check_database_upgrade()

###############################################
# Return HTML header for all pages
sub header { 
    my $html = qq~
    <!doctype html>
    <html lang="en" class="dark">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>$app_title / $list_name</title>

    <link rel="icon" href="/favicon.ico" type="image/x-icon">

    <link rel="stylesheet" href="/static/css/bootstrap.min.css">
    <link rel="stylesheet" href="/static/css/jquery.dataTables.min.css">
    <link rel="stylesheet" href="/static/css/buttons.dataTables.min.css">

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
        body { background-color: #1A2122; }
        .card-dark { background-color: #0f1724; border-color: rgba(255,255,255,0.05); }
        .muted { color: rgba(255,255,255,0.65); }
        .dt-hidden { visibility: hidden; }
        .header-bar { min-height: 72px; }
        .dataTables_paginate .paginate_button.disabled { display: none !important; }
        .icon { width: 1em; height: 1em; vertical-align: middle; }
    </style>

    </head>
    <body 
        class="text-white d-flex flex-column min-vh-100"
        ~;

    if ($config->{'cfg_background_image'} eq 'on') {   # Show a background if enabled. Use the mtime of the file to trigger a cache reload by the client
        my $bg_mtime = (stat("./static/background.jpg"))[9] || time();  
        $html .= qq~ style="background: url('/static/background.jpg?v=$bg_mtime') center / cover no-repeat;" ~;
        }

    $html .= qq~
        >
    <main class="flex-grow-1 container py-4">
        <div class="row justify-content-center">
            <div class="col-md-10">
            ~;

    # Header bar
    $html .= qq~
    <div class="container py-1">
        <div class="d-flex flex-column flex-md-row justify-content-between align-items-start align-items-md-center gap-2 mb-4">
            <div class="d-flex align-items-center gap-2">
                <a href="/" class="d-flex align-items-center gap-2 text-white text-decoration-none">
                    <img src="/static/taskpony-logo.png" width="82" height="82" alt="logo">
                    <h3 class="mb-0">$app_title</h3>
                </a>                
                ~;
    
    # Add the list selection pulldown
    $html .= list_pulldown($list_id);  

    $html .= qq~
                    </div>
                    <div class="btn-group" role="group">
            ~;

    # Show completed/active button
    if ($show_completed == 0) {  # We're on the active tasks page, so show button for completeds
                my $cnt_completed_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 2 AND ListId = $list_id");
                if ($list_id == 1) {
                    $cnt_completed_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 2");
                    }                
                $html .= qq~
                <a href="/?sc=1"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center"
                    data-bs-toggle="tooltip" data-bs-placement="auto"title="Show $cnt_completed_tasks completed tasks in '$list_name'" >
                    $icon_rotate_left
                </a>
                ~;
                } else { # We're showing completed tasks, so show button for the active list
                my $cnt_active_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 1 AND ListId = $list_id");
                if ($list_id == 1) {
                    $cnt_active_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 1");
                    }
                $html .= qq~
                <a href="/"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Show $cnt_active_tasks active tasks in '$list_name'" >
                    $icon_rotate_right
                </a>
                ~;
                } # End active/completed button

                $html .= qq~
                <a href="/lists"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Manage Lists" >
                    $icon_list
                </a>

                <a href="/stats"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center justify-content-center btn-icon"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Statistics" >
                    $icon_chart
                </a>

                <a href="/config"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center justify-content-center btn-icon"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Settings" aria-label="Settings">
                    $icon_gear
                </a>
                
            </div>
        </div>
    ~;

    return $html;
    } # End header()

###############################################
# Return standard HTML footer for all pages
sub footer { 
    my $html = show_alert();  # If there is an alert in ConfigTb waiting to be shown, display it above the footer.

    $html .= qq~
            </div>
        </div>
        <br/>
        </main>
        <footer class="text-center text-white-50 py-2">
            <p>
            ~;

    # Show label for a new version if it exists
    if ( ($config->{cfg_version_check} eq 'on') && ($new_version_available == 1 ) ) {
        $html .= qq~
            <span class="badge rounded-pill  bg-$config->{cfg_header_colour}">
                <a href="$app_releases_page" class="text-white text-decoration-none" target="_blank">
                    New version available
                </a>
            </span> 
            &nbsp;
        ~;
        }

    $html .= qq~
            <a href="https://github.com/digdilem/taskpony">$app_title v.$app_version</a> by <a href="https://digdilem.org/" class="text-white">Digital Dilemma</a>
            </p>
        </footer>

        <script>
            \$(document).ready(function() {
            \$('#tasks').DataTable({
                paging:   true,
                ordering: true,
                info:     true,
                autoWidth: false,
                columnDefs: [{ width: '10%', targets: 0 }],
                initComplete: function () { 
                    \$('#tasks').removeClass('dt-hidden'); 
                    \$('#hideUntilShow').removeClass('d-none'); 
                    \$('#hideUntilShow2').removeClass('d-none'); 
                    },
                ~;

            # Show search if configured
            if ($config->{'cfg_include_datatable_search'} eq 'on') {
                $html .= qq~
                "searching": true,
                ~;
                } else {
                $html .= qq~
                "searching": false,
                ~;
                }

            # Continue
            $html .= qq~
                "pageLength": $config->{cfg_task_pagination_length},
                ~;

            # Show buttons if configured, otherwise show default dom
            if ($config->{'cfg_include_datatable_buttons'} eq 'on') {
                $html .= "dom: 'ftiBp',";
                } else {
                $html .= "dom: 'ftip',";
                }

            $html .= qq~
                buttons: [
                ~;

            # Set buttons configuration, including whether to export all columns or just the first
            if ($config->{'cfg_export_all_cols'} eq 'on') {
                    $html .= qq~
                    { extend: 'copy', className: 'btn btn-dark btn-sm' },
                    { extend: 'csv', className: 'btn btn-dark btn-sm' },
                    { extend: 'pdf', className: 'btn btn-dark btn-sm'},
                    { extend: 'print', className: 'btn btn-dark btn-sm' }
                    ~;
                    } else {
                    $html .= qq~
                    { extend: 'copy', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]}  },
                    { extend: 'csv', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]}  },
                    { extend: 'pdf', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]} },
                    { extend: 'print', className: 'btn btn-dark btn-sm', exportOptions: {columns: [1]}  }
                    ~;
                    }

            $html .= qq~
                ],
                "language": {
                    "emptyTable": "No tasks found! 🎉",
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
        }, 5000);
        </script>

        </body>
        </html>
        ~;

    return $html;
    } # End footer()

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
        }

    # Get lists from ListsTb
    my $sth = $dbh->prepare('SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL ORDER BY IsDefault DESC,Title ASC');
    $sth->execute();

    # Prepend the "All lists" option and then loop through, adding each. 
    while (my $row = $sth->fetchrow_hashref()) {
        my $selected = ($row->{'id'} == $selected_lid) ? ' selected' : '';
        my $title = sanitize($row->{'Title'});
        my $list_count = single_db_value( 'SELECT COUNT(*) FROM TasksTb WHERE ListId = ? AND Status = 1', $row->{'id'} ) // 0;

        if ($row->{'id'} == 1) { # All lists option
            $list_count = single_db_value( 'SELECT COUNT(*) FROM TasksTb WHERE Status = 1' ) // 0;
            $title = 'All Tasks';
            }
        $html .= qq~<option value="$row->{'id'}"$selected>$title ($list_count tasks)</option>\n~;
        }

    $html .= '</select>';
    return $html;
    } # End list_pulldown()

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
    } # End sanitize()

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
    } # End html_escape()

###############################################
# single_db_value($sql, @params)
# Execute a SQL query that returns a single value
sub single_db_value {
    my ($sql, @params) = @_;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my ($value) = $sth->fetchrow_array();
    return $value;
    } # End single_db_value()

###############################################
# debug($msg)
# Print debug message if debugging is globally enabled
sub debug {
    my $msg = shift;
    if ($debug == 1) {
        print STDERR "DEBUG: $msg\n";
        }
    } # End debug()

###############################################
# show_tasks($status, $list_id)
# Return HTML table of tasks with given status (1=active,2=completed) for given list_id (1=all lists)
sub show_tasks {
    my ($status, $list_id) = @_;

    # Build SQL query
    my $sql = "
        SELECT t.id, t.Title, t.Description, t.AddedDate, t.CompletedDate, t.ListId, t.IsRecurring, t.RecurringIntervalDay, p.Title AS ListTitle
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

    my $html = qq~
        <table id="tasks" class="display hover table-striped dt-hidden mb-3" style="width:90%">
            <thead>
                <tr>
                    <th>&nbsp;</th>
                    <th>Title</th>
        ~;

        # Show or hide date column based on config
        if ($config->{'cfg_show_dates'} eq 'on') {

            if ($status == 1) {  # Active tasks. Show added date
                $html .= "            <th>Added</th>\n";
                } else { # Completed tasks. Show completed date
                $html .= "<th>Completed</th>\n";
                }
            } 

        # Show or hide list column based on config
        if ($config->{'cfg_show_lists'} eq 'on') {
                    $html .= qq~<th>List</th>
                    ~;
            } 

        # Close row
        $html .= qq~
                </tr>
            </thead>
            <tbody>
            ~;

    # Loop through each task and output a row for each. Add data-order so that Datatables can sort by actual date value instead of human friendly string
    while (my $a = $sth->fetchrow_hashref()) {
        my $friendly_date = qq~
            <td data-order="$a->{'AddedDate'}">
                <a href="#" class="text-reset text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Added at: $a->{'AddedDate'}">
                ~
                . human_friendly_date($a->{'AddedDate'}) . qq~</a> 
            </td>
            ~;

        if ($status != 1) { # Completed tasks, show CompletedDate instead
            $friendly_date = qq~
            <td data-order="$a->{'CompletedDate'}">
                <a href="#" class="text-reset text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Completed at: $a->{'CompletedDate'}">
                ~
                . human_friendly_date($a->{'CompletedDate'}) . qq~</a>
            </td>
            ~;
            }

        my $checkbox = '';
        my $title_link;
        my $description = html_escape(substr($a->{'Description'},0,$config->{'cfg_description_short_length'}));
        my $title = html_escape($a->{'Title'});
        my $list_title = substr(html_escape($a->{'ListTitle'} // 'Unknown'),0,$config->{cfg_list_short_length});

        ###############################################
        # Check to see whether the List this task belongs to is deleted and if so, show it as being orphaned

        my $list_deleted = single_db_value("SELECT COUNT(*) FROM ListsTb WHERE id = ? AND DeletedDate IS NOT NULL", $a->{'ListId'}) // 0;
        if ($list_deleted != 0) { # List is deleted, this task is an orphan
            $list_title = '[--No List--]';

            # Prefix task title with an orphaned marker, coloured red
            $title_link .= qq~<span class="text-$config->{cfg_header_colour}" data-bs-toggle="tooltip" data-bs-placement="auto" title="This task belongs to a deleted list">
                $icon_link_slash
            </span>
            ~;
            }

        # Add a repeat icon if the task is recurring
        if (defined $a->{'IsRecurring'} && $a->{'IsRecurring'} eq 'on') {
            $title_link .= qq~<span class="text-$config->{cfg_header_colour}" data-bs-toggle="tooltip" data-bs-placement="auto" title="This is a repeating task. Once completed, it will reactivate after $a->{RecurringIntervalDay} days">
                $icon_repeat_small
            </span> ~;
            }            
        
        # Active tasks. Show checkbox to mark complete
        if ($status == 1) {  
            $checkbox .= qq~
                <form method="post" action="/complete" style="display:inline;">
                    <input type="hidden" name="task_id" value="$a->{'id'}" />
                    <input type="checkbox" class="form-check-input" style="cursor:pointer; transform:scale(1.2);" onchange="this.form.submit();" />
                </form>
                ~;

            $title_link .= qq~
                    <a 
                    href="/edittask?id=$a->{'id'}"
                    class="text-white text-decoration-none" 
                    data-bs-toggle="tooltip" data-bs-placement="auto"
                    title="$description">
                        $title
                    ~;
            if ($description) {
                $title_link .= qq~<span class="text-$config->{cfg_header_colour}">&nbsp; $icon_comment_small
                </span> 
                ~;
                }
            $title_link .= qq~
                    </a>
                     ~;
            } 

        # Completed tasks. Show undo button to mark uncompleted
        if ($status == 2) { # Completed tasks
            $title_link .= qq~
                    <a 
                    href="/edittask?id=$a->{'id'}"
                    class="text-white text-decoration-none" 
                    data-bs-toggle="tooltip" data-bs-placement="auto" 
                    title="$description Completed ~ . human_friendly_date($a->{'CompletedDate'}) . qq~">
                        <span class="opacity-50">$title</span>
                    </a>
                     ~;

            $checkbox .= qq~
                <a href="/ust?task_id=$a->{'id'}&sc=1" class="btn btn-sm btn-secondary" title="Mark as uncompleted">
                $icon_rotate_left_small
                </a>
                ~;
            }
        
        ###############################################
        # Output the table row
        ###############################################
        $html .= qq~
            <tr>                
                <td>$checkbox</td>
                <td>$title_link</td>
                ~;

        ###############################################
        # Show or hide date and list column header based on config var cfg_show_dates
        $html .= qq~
                <!-- Date column -->
                ~;        
        if ($config->{'cfg_show_dates'} eq 'on') {
            $html .= qq~
                <td>
                    $friendly_date
                </td>
                ~;
            }

        ###############################################
        # Show or hide date and list column header based on config var cfg_show_dates_lists
        $html .= qq~
                <!-- List column -->
                ~;
            
        if ($config->{'cfg_show_lists'} eq 'on') {  
            if ($list_deleted != 0) { # List is deleted, no link
                $html .= qq~
                        $list_title
                    </td>
                    ~;
                } else {
                $html .= qq~
                        <a 
                        href="/?lid=$a->{'ListId'}"
                        class="text-white text-decoration-none" 
                        data-bs-toggle="tooltip" data-bs-placement="auto"
                        title="Jump to $a->{'ListTitle'}">
                        $list_title
                        </a>
                    </td>
                    ~;
                }
            }

        # Close the row
        $html .= qq~
            </tr>
        ~;
    } # End tasks loop

    # Close table and add JS script to reload page if database has changed (Stats table page only)
    $html .= qq~
            </tbody>
        </table>
        <br><br>

        <!-- Reload page if DB changed -->
        <script>
        (function () {
        let lastValue = Number($db_mtime);

        async function checkDbStats() {
            try {
            const response = await fetch("/api/dbstate", {
                cache: "no-store"
            });

            if (!response.ok) return;

            const text = await response.text();
            const currentValue = parseInt(text.trim(), 10);

            if (!Number.isFinite(currentValue)) return;

            if (currentValue !== lastValue) {
                window.location.reload();
            }
            } catch (e) {
            // Fail silently
            }
        }
        
        setInterval(checkDbStats, $db_interval_check_ms);
        })();
        </script> <!-- End DB stats check script -->

        ~;

    return $html;
    } # End show_tasks()

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
    } # End show_alert()

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
    } # End add_alert()

###############################################
# human_friendly_date($db_date)
# Convert a database datetime string into a human friendly relative time string
sub human_friendly_date {
    my ($db_date) = @_;
    return '' unless defined $db_date;
        
    my ($year, $month, $day, $hour, $min, $sec) =  $db_date =~ /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/;
    
    return $db_date unless $year;  # Return original if parse fails
    
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
    } # End human_friendly_date()

###############################################
# config_load()
# Load all key/value pairs from ConfigTb into $config hashref
sub config_load {
    print STDERR "Loading configuration from $db_path in ConfigTb\n";

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

    check_latest_release();
    } # End config_load()

###############################################
# Open a consistent bootstrap 5 card for most pages
sub start_card {
    my $card_title = shift || 'Title Missing';
    my $card_icon = shift || '';
    my $table_card = shift || 0;  # If 1, forces a reload after datatables to reduce flicker

    my $html = qq~ <div class="card shadow-sm mb-4"> ~;

    if ($table_card == 1) { $html = qq~ <div class="card shadow-sm d-none " id="hideUntilShow" >~; }  # If a table, hide the whole card until loaded

    $html .= qq~
                        <div class="card-header bg-$config->{cfg_header_colour} text-white">
                            <h2 >
                                $card_title
                                ~;
                            if ($card_icon ne '') {
                                $html .= qq~
                                                        <div class="float-end">$card_icon</div>
                                                        ~;
                                }
                            $html .= qq~
                            </h2>
                        </div>

                        <div class="card-body bg-dark text-white rounded-bottom">~;
    return $html;
    } # End start_card()

###############################################
# As above, but smaller. Used for second cards on a page (Eg: Add List)
sub start_mini_card {
    my $card_title = shift || 'Title Missing';
    my $card_icon = shift || '';
    my $html = qq~
        <div class="container py-5">
            <div class="row justify-content-center">
                <div class="col-md-11">
                    <div class="card shadow-sm mb-2">
                        <div class="card-header bg-$config->{cfg_header_colour} text-white">
                            <h2 class="mb-0">
                                $card_title
                                ~;
    if ($card_icon ne '') {
        $html .= qq~
                                <div class="float-end">$card_icon</div>
                                ~;
        }
    $html .= qq~
                            </h2>
                        </div>

                        <div class="card-body bg-dark text-white rounded-bottom">~;
    return $html;
    } # End start_mini_card()

###############################################
# Close the card
sub end_card {
    my $html = qq~
                            </div>
                        </div>
                    </div>
        ~;
    return $html;
    } # End end_card()

###############################################
# calculate_stats()
sub calculate_stats { # Calculate stats and populate the global $stats hashref
    # Check to see whether we've run this recently. If so, return before hitting the database
    if ( $stats->{stats_last_calculated} && time - $stats->{stats_last_calculated} < $calculate_stats_interval ) { return; }

    # Before we get onto working out the stats, check whether the daily tasks have been run today
    run_daily_tasks();  # Will return early if already run today

    print STDERR "Calculating task statistics...\n";
    my $sql = q{
        SELECT
            COUNT(*)                                                    AS total_tasks,
            IFNULL(SUM(CompletedDate IS NULL), 0)                                 AS active_tasks,

            IFNULL(SUM(date(AddedDate) = date('now','localtime')), 0)             AS tasks_added_today,
            IFNULL(SUM(AddedDate >= date('now','-7 days','localtime')), 0)        AS tasks_added_past_week,
            IFNULL(SUM(AddedDate >= date('now','-1 month','localtime')), 0)       AS tasks_added_past_month,
            IFNULL(SUM(AddedDate >= date('now','-1 year','localtime')), 0)        AS tasks_added_past_year,

            IFNULL(SUM(CompletedDate IS NOT NULL), 0)                              AS completed_tasks,
            IFNULL(SUM(date(CompletedDate) = date('now','localtime')), 0)         AS tasks_completed_today,
            IFNULL(SUM(CompletedDate >= date('now','-7 days','localtime')), 0)    AS tasks_completed_past_week,
            IFNULL(SUM(CompletedDate >= date('now','-1 month','localtime')), 0)   AS tasks_completed_past_month,
            IFNULL(SUM(CompletedDate >= date('now','-1 year','localtime')), 0)    AS tasks_completed_past_year
        FROM TasksTb
        };

    my $row = $dbh->selectrow_hashref($sql);

    # Merge DB values into existing stats hashref
    @$stats{ keys %$row } = values %$row;

    $stats->{total_lists} = $dbh->selectrow_array('SELECT COUNT(*) FROM ListsTb');
    $stats->{total_active_lists} = $dbh->selectrow_array('SELECT COUNT(*) FROM ListsTb WHERE DeletedDate IS NULL');
    $stats->{stats_first_task_created} = $dbh->selectrow_array("SELECT IFNULL(MIN(AddedDate), 'N/A') FROM TasksTb");
    $stats->{stats_first_task_created_daysago} = $dbh->selectrow_array("SELECT IFNULL(CAST((julianday('now') - julianday(MIN(AddedDate))) AS INTEGER), 0) FROM TasksTb");
    $stats->{repeating_tasks} = $dbh->selectrow_array('SELECT COUNT(*) From TasksTb WHERE IsRecurring = "on"');

    $stats->{stats_last_calculated} = time;
    } # End calculate_stats()    

###############################################
# Run any daily tasks we need to. Return if already run today.
sub run_daily_tasks {
    my $tasks_ran_today = $dbh->selectrow_array("
        SELECT CASE
        WHEN value = date('now') THEN 1
        ELSE 0
        END
        FROM ConfigTb
        WHERE key = 'cfg_last_daily_run';
        ");

    if ($tasks_ran_today == 1) { return; }  # Already ran today, return

    print STDERR "Running daily tasks...\n";

    ###############################################
    # Run daily tasks here, such as backing up the database, sending email summaries, etc.
    backup_database();  # Backup the database by one iteration

    ###############################################
    # Look for any recurring tasks that need to be reactivated today
    my $recurring_sth = $dbh->prepare("
        SELECT id, Title, Description, AddedDate, CompletedDate, ListId, RecurringIntervalDay
        FROM TasksTb
        WHERE IsRecurring = 'on' AND Status = 2 AND CompletedDate IS NOT NULL
        ");
    $recurring_sth->execute();

    while (my $task = $recurring_sth->fetchrow_hashref()) {
        my $completed_date = $task->{'CompletedDate'};
        my $interval_days = $task->{'RecurringIntervalDay'} // 1;  # Default to 1 day if not set

        # Calculate the next activation date
        my $next_activation_date = single_db_value("
            SELECT date(?, '+' || ? || ' days')
            ", $completed_date, $interval_days);

        debug("Recurring task ID $task->{id} ('$task->{Title}') completed on $completed_date with interval $interval_days days. Next activation date: $next_activation_date\n");

        # If the next activation date is today or earlier, reactivate the task
        if ($next_activation_date le single_db_value("SELECT date('now')")) {
            print STDERR "Reactivating recurring task ID $task->{id} ('$task->{Title}') after $interval_days days\n";

            # Reactivate the task
            $dbh->do("
                UPDATE TasksTb
                SET Status = 1,
                    CompletedDate = NULL,
                    AddedDate = date('now')
                WHERE id = ?
                ", undef, $task->{'id'}
                ) or print STDERR "WARN: Failed to reactivate recurring task ID $task->{id}: " . $dbh->errstr;
            }
        }

    ###############################################
    # We ran run_daily_tasks() today, so let's update the last run time and return
    $dbh->do("UPDATE ConfigTb SET value = date('now') WHERE key = 'cfg_last_daily_run'") or print STDERR "WARN: Failed to update last daily run date: " . $dbh->errstr;
    return;
    } # End run_daily_tasks()

###############################################
# Backup the database by rotating old backups and creating a new one. Will only be called once a day from run_daily_tasks() logic
sub backup_database {
    print STDERR "Backing up database...  Keeping " . $config->{cfg_backup_number_to_keep} . " backups\n";

    # Start counting back from the currently defined max backups to keep. Delete the oldest, then rename each one down by 1, then create the new backup as .0
    for (my $i = $config->{cfg_backup_number_to_keep} - 1; $i >= 0; $i--) {
        my $old_backup = "$db_path.$i";
        my $new_backup = "$db_path." . ($i + 1);
        print STDERR "Processing backup rotation: $old_backup to $new_backup\n";

        if (-e $old_backup) {
            if ($i == $config->{cfg_backup_number_to_keep} - 1) {
                # This is the oldest backup, delete it
                print STDERR "Deleting oldest backup: $old_backup\n";
                unlink $old_backup or print STDERR "WARN: Failed to delete old backup $old_backup: $!\n";
                } else {
                # Rename the backup down by 1
                print STDERR "Renaming backup: $old_backup to $new_backup\n";
                rename $old_backup, $new_backup or print STDERR "WARN: Failed to rename backup $old_backup to $new_backup: $!\n";
                }
            }
        }
    # Now create the new backup as .0
    my $new_backup_0 = "$db_path.0";
    print STDERR "Creating new backup by copying $db_path to $new_backup_0\n";
    copy($db_path, $new_backup_0) or print STDERR "WARN: Failed to create new backup $new_backup_0: $!\n";
    } # End backup_database()

###############################################
# save_config()
# Save contents of $config hashref to ConfigTb
sub save_config {
    print STDERR "Saving configuration\n";

    # First, check any numbers are sensible
    ensure_sensible_config_range('cfg_task_pagination_length', 3, 1000);        # Number of tasks to show per page 
    ensure_sensible_config_range('cfg_description_short_length', 3, 1000);      # Number of characters to show in task list before truncating description 
    ensure_sensible_config_range('cfg_list_short_length', 1, 100);             # Number of characters to show in task list before truncating list name
    ensure_sensible_config_range('cfg_backup_number_to_keep', 1, 100);           # Number of database backups to keep

    # Loop through $config keys and save each of them to ConfigTb
    for my $key (keys %$config) {
        my $sql = "INSERT INTO ConfigTb (`key`,`value`) 
            VALUES (?, ?) 
            ON CONFLICT(key) 
            DO UPDATE SET value = excluded.value;";

        $dbh->do(
            $sql,
            undef,
            $key,
            $config->{$key},
            ) or warn "Failed to save config key ($key): " . $dbh->errstr;
        }
    } # End save_config()

###############################################
# ensure_sensible_config_range($value, $min, $max)
# Ensure a numeric value is within a sensible range, otherwise return the nearest bound
# This may now be redundant with bootstrap range values sanitising on input, but it's good to have server-side checks too
sub ensure_sensible_config_range {
    my ($config_key, $min, $max) = @_;
    my $value = $config->{$config_key};

    if ($value !~ /^\d+$/) {
        print STDERR "WARN: Config value for $config_key is not a number. Resetting to $min.\n";
        $config->{$config_key} = $min;
        }
    if ($value < $min) {
        print STDERR "WARN: Config value for $config_key ($value) is below minimum ($min). Resetting to $min.\n";
        $config->{$config_key} = $min;
        }
    if ($value > $max) {
        print STDERR "WARN: Config value for $config_key ($value) is above maximum ($max). Resetting to $max.\n";
        $config->{$config_key} = $max;
        }
    } # End ensure_sensible_config_range()

###############################################
# check_latest_release()
# Get latest release from github
sub check_latest_release {    
    if ($config->{'cfg_version_check'} ne 'on') { return; }             # If disabled, return early
    if ($new_version_available == 1) { return; }                       # No point checking again if we know there is a new version waiting

    my $github_latest_version;

    my $http = HTTP::Tiny->new(
        agent => 'taskpony-version-check/$app_version',
        timeout => 10
        );

    my $res = $http->get($github_version_url);
    if ($res->{success}) {
        my $data = decode_json($res->{content});
        $github_latest_version = $data->{tag_name};
        $github_latest_version =~ s/\D//g;   # Just return the digits for numeric comparison
        } else {
        print STDERR "Latest version check from github failed. Non-fatal, continuing\n";
        return;        
        }
    
    my $normalised_app_version = $app_version;
    $normalised_app_version =~ s/\D//g;

    if ($github_latest_version > $normalised_app_version) {
        print STDERR "New version of $app_title is available\n";
        $new_version_available = 1;
        }
    return;
    }  # End check_latest_release()

###############################################
# config_show_option($key, $title, $description, $type (check, number, colour), $num_range_lower, $numrange_upper);
# Output a line of a setting  for /config forms
sub config_show_option { 
    my ($key, $title, $description, $type, $num_range_lower, $num_range_upper) = @_;

    my $retstr= qq~
        <!-- Display config option for $key -->
        <div class="d-flex align-items-center justify-content-between p-3 bg-dark text-white rounded" style="max-width: 500px;">
            <label class="form-check-label" for="$key" data-bs-toggle="tooltip" data-bs-placement="auto" title="$description" >
            $title
            </label> ~;

    if ($type eq 'check') {  # Checkbox 
        $retstr .= qq~
            <div class="form-check form-switch mb-0">
                <input class="form-check-input " type="checkbox" role="switch" id="autoUpdateToggle" name="$key" ~;
                
            if ($config->{$key} eq 'on') { $retstr .= " checked "; }

            $retstr .= qq~>
            </div>
            ~;
        } 
    
    if ($type eq 'number') { # Numerical entry
        $retstr .= qq~
            <input type="number" class="form-control w-25" 
                value="$config->{$key}" 
                name="$key"
                min="$num_range_lower" max="$num_range_upper">
            ~;
        }

    if ($type eq 'colour') { # Colour picker
        $retstr .= qq~
            <select class="form-select w-25" id="themeColor" name="$key">                                        
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
            ~;
        }

    $retstr .= qq~
        </div>
        <!-- End Display config option for $key -->
        ~;

    return $retstr;
    } # end config_show_option()

###############################################
# build_icon($size,$svg);
sub build_tabler_icon {
    my ($size, $svg) = @_;

    return qq~<span style="font-size: ~ . $size . qq~px;">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon">$svg</svg>
        </span>~;
    } # end build_tabler_icon

###############################################
# Update the global $db_mtime variable with the current database file modification time
sub update_db_mtime {
    $db_mtime = (stat($db_path))[9] // 0;    
    }

##############################################
# End Functions

#################################################
# End of file
