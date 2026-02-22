#!/usr/bin/env/perl
# Taskpony - a simple perl PSGI web app for various daily tasks - https://github.com/digdilem/taskpony
# Started Christmas, 2025. Simon Avery / digdilem / https://digdilem.org
# MIT Licence = Free to use and modify as you see fit, but please give credit where due.

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
use FindBin qw($Dir);           # To find Taskpony's Paddock (starting directory)

###############################################
# Path to Taskpony installation root and associated dirs.
my $taskpony_path = $Dir;
#my $global->{'db_path'} = "$Dir/db/taskpony.db";          # Path to Sqlite database file that's valid if native or in docker. If not present, it will be auto created
#my $global->{'bg_path'} = "$Dir/static/background.jpg";   # Path to the background picture, if used. This should be writeable by the taskpony process to allow uploads and must be in ./static for serving.

my $dbh;                            # Global database handle

our $config = {
    # Default user editable configuration values. Don't change them here, use /settings page.
    cfg_task_pagination_length => 25,           # Number of tasks to show per page
    cfg_description_short_length => 35,         # Number of characters to show in task list before truncating description (Cosmetic only)
    cfg_list_short_length => 20,                # Number of characters to show in list column in task display before truncating (Cosmetic only)
    cfg_include_datatable_buttons => 'on',      # Include the CSV/Copy/PDF etc buttons at the bottom of each table
    cfg_include_datatable_search => 'on',       # Include the search box at the top right of each table
    cfg_export_all_cols => 'off',               # Export all columns in datatable exports, not just visible ones
    cfg_show_dates => 'on',                     # Show just tasks, hide Date and List columns in task list
    cfg_show_lists => 'off',                    # Show the Lists column in task list
    cfg_header_colour => 'success',             # Bootstrap 5 colour of pane backgrounds and highlights
    cfg_last_daily_run => 0,                    # Date of last daily run
    cfg_backup_number_to_keep => 7,             # Number of daily DB backups to keep
    cfg_version_check => 'on',                  # Whether to occasionally check for new releases
    cfg_background_image => 'on',               # Whether to display a background image
    cfg_show_quickswitcher => 'on',             # Whether to enable quickswitch (Colour buttons at the top)
    database_schema_version => 1,               # Default. Don't ever change this. Current version will be read from the database on startup on existing installs.
    };

###############################################
# Global variables that are used throughout - do not change these.
our $global = {
    app_title => 'Taskpony',                    # Name of app
    app_version => '0.6',                       # Version of app
    database_schema_version => 2,               # Target database schema version. If config value is below this, then auto upgrade will be attempted.
    github_version_url => 'https://api.github.com/repos/digdilem/taskpony/releases/latest',     # Used to get latest version for upgrade notification
    app_releases_page => 'https://github.com/digdilem/taskpony',                                # Where new versions are
    new_version_available => 0,                 # Set to 1 if a new version is available on github
    taskpony_icon => 'taskpony-logo.png',       # Default icon file name in ./static dir
    tooltip_delay => 'show: 250, hide: 1',     # Global tooltip delay for all tooltips in the app
    debug => 0,                                 # Set to 1 to enable debug messages to STDERR
    running_in_docker => 0,                     # Set to 1 if running in docker, 0 if not
    db_path => "$Dir/db/taskpony.db",           # Path to Sqlite database file that's valid if native or in docker. This will be updated to the correct path on startup.
    bg_path => "$Dir/static/background.jpg"     # Path to background image file, valid in docker or native. This will be updated to the correct path on startup.
    };

###############################################
# Page specific variables.
our $page = {
    list_id => 0,                   # Current list id
    list_name => '',                # Current list name
    list_colour => '',              # Current list highlight colour (overrides default)
    alert_text => '',               # If set, show this alert text on page load
    show_completed => 0,            # If set to 1, show completed tasks instead of active ones
    do_mtime => 1,                  # If set to 1, the page will check /api/dbstate every $page->{'db_interval_check_ms'} milliseconds to see if the database has changed
    db_interval_check_ms => 60000,  # How many milliseconds between checking /api/dbstate for changes to know when to reload the tasks page
    default_listid => 0,            # default ListId from ListsTb
    };

###############################################
# Statistics variables. Not stored in config. Recalculated periodically and updated on change.
my $stats = {
    calculate_stats_interval => 3600,       # Wait at least this many seconds between recalculating stats. (Only checked on web activity)
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

# New icons to be saved in /static/icons and alt text matches the filename.svg
my $icons = {
    chart => build_tabler_icon('Statistics'),  # Chart icon
    plus => build_tabler_icon('Plus'),  # Plus icon
    edit => build_tabler_icon('Edit'),    # Edit / pencil icon
    gear => build_tabler_icon('Settings'),  # Settings gear cog
    grave => build_tabler_icon('Grave'),  # Grave icon
    image => build_tabler_icon('Image'),  # Image / picture icon
    info => build_tabler_icon('Info'),  # Info icon
    list => build_tabler_icon('List'),      # List icon
    list_add => build_tabler_icon('ListAdd'),  # List with plus icon
    repeat => build_tabler_icon('Repeat'),  # Repeat / recurring icon
    rotate_left => build_tabler_icon('ArrowLeft'),  # Rotate left icon
    rotate_right => build_tabler_icon('ArrowRight'),  # Rotate right icon
    sleep => build_tabler_icon('Zzz'),  # Sleep / Zzz icon
    star_off => build_tabler_icon('StarOff'),  # Star outline icon
    star_on => build_tabler_icon('StarOn'),    # Star filled icon
    trash => build_tabler_icon('Trash'),  # Trash can icon
    xcircle => build_tabler_icon('XCircle'),  # X in circle icon
    };

my $smallicons = { # Similar idea as above, but these are coloured in the current highlight colour
    comment => build_inline_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M8 9h8" /><path d="M8 13h6" /><path d="M18 4a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3h-5l-5 3v-3h-2a3 3 0 0 1 -3 -3v-8a3 3 0 0 1 3 -3h12" />'),
    link => build_inline_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M9 15l6 -6" /><path d="M11 6l.463 -.536a5 5 0 0 1 7.071 7.072l-.534 .464" /><path d="M13 18l-.397 .534a5.068 5.068 0 0 1 -7.127 0a4.972 4.972 0 0 1 0 -7.071l.524 -.463" />'),
    repeat => build_inline_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 12v-3a3 3 0 0 1 3 -3h13m-3 -3l3 3l-3 3" /><path d="M20 12v3a3 3 0 0 1 -3 3h-13m3 3l-3 -3l3 -3" />'),
    edit => build_inline_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M7 7h-1a2 2 0 0 0 -2 2v9a2 2 0 0 0 2 2h9a2 2 0 0 0 2 -2v-1" /><path d="M20.385 6.585a2.1 2.1 0 0 0 -2.97 -2.97l-8.415 8.385v3h3l8.385 -8.415" /><path d="M16 5l3 3" />'),
    listnumbers => build_inline_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M11 6h9" /><path d="M11 12h9" /><path d="M12 18h8" /><path d="M4 16a2 2 0 1 1 4 0c0 .591 -.5 1 -1 1.5l-3 2.5h4" /><path d="M6 10v-6l-2 2" />'),
    plus => build_inline_icon(16,'<path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 5l0 14" /><path d="M5 12l14 0" />'),
    };


# Preflight checks
print STDERR "Loading Taskpony $global->{'app_version'}...\n";
print STDERR "Paddock is '$taskpony_path'\n";
connect_db();                   # Connect to the database
config_load();                  # Load saved config values

print STDERR "\n+-----Welcome to Taskpony! ----------+\n";
print STDERR "|  [X] Install Taskpony              |\n";
print STDERR "|  [ ] Do the thing                  |\n";
print STDERR "|  [ ] Buy milk                      |\n";
print STDERR "+------------------------------------+\n\n";

####################################
# Start main loop

my $static_dir = catdir($FindBin::Bin);
if (-f '/.dockerenv') { $global->{'running_in_docker'} = 1; }  # Test for this magical file that docker created.

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    my $res = Plack::Response->new(200);
    if (not $dbh->ping) { connect_db(); }      # Reconnect to DB if needed

    # Global modifiers and preflight checks we should ensure are done on each page load
    my $list_switched = 0;
    if ($req->param('lid') && $req->param('lid') =~ /^\d+$/) {
        $page->{'list_id'} = $req->param('lid');  # Set active list to supplied (only if numeric)
        debug("List ID supplied in URL, switching to list id $page->{'list_id'} and calling set_default_listid()");
        set_default_listid($page->{'list_id'});  # Save the selection to ConfigTb for next time
        $list_switched = 1;
        }
    if ($page->{'list_id'} == 0)        { $page->{'list_id'} = return_default_listid(); }         # if this is 0, Taskpony has probably just restarted so load the default list
    if ($page->{'default_listid'} == 0) { $page->{'default_listid'} = return_default_listid(); }

    verify_valid_list($list_switched);      # Verify active list details are valid, force reload if switched
    calculate_stats();                          # Update stats hashref if needed
    update_db_mtime();                          # Ensure we have the latest mtime cached as $page->{'db_mtime'}

    $page->{'show_completed'} = $req->param('sc') // 0;   # If ?sc=1 we want to show completed tasks. !!

    ###############################################
    # Preflight checks done. First, check with simple redirectors
    ###############################################
    debug("Handling request for path: " . $req->path);

    # Handle favicon requests
    if ($req->path eq "/favicon.ico") {  $res->redirect('./static/favicon.ico'); return $res->finalize; }

    ###############################################
    # !ACTION functions
    # Action /task_complete/nn - Mark task nn as completed and redirect to home page
    if ($req->path =~ m{^/task_complete/(\d+)$})        { action_task_complete($1);     $res->redirect('/'); return $res->finalize; }
    # Action /task_delete/nn - Permanently delete task nn and redirect to home page
    if ($req->path =~ m{^/task_delete/(\d+)$})          { action_task_delete($1);       $res->redirect('/'); return $res->finalize; }
    # Action /task_activate/nn - Set task nn as active again and redirect to home page
    if ($req->path =~ m{^/task_activate/(\d+)$})        { action_task_activate($1);     $res->redirect('/'); return $res->finalize; }
    # Action /task_edit/nn - Show edit form for task nn, or if POST, update task nn and redirect to home page. Function returns full html
    if ($req->path =~ m{^/task_edit/(\d+)$})            { $res->body(action_task_edit($1));   return $res->finalize; }
    # Action /task_add - Show add task form (No number)
    if ($req->path eq "/task_add")                      { $res->body(action_task_add());       return $res->finalize; }


    # !LIST ACTIONS
    # Change active list to NN and show tasks in that list
    if ($req->path =~ m{^/list/(\d+)$})                 { $page->{'list_id'} = $1;      verify_valid_list(1);   $res->redirect('/'); return $res->finalize; }
    # Set LIST nn as UnDeleted (Active)
    if ($req->path =~ m{^/list_unarchive/(\d+)$})       { action_list_unarchive($1);     $res->redirect('/lists'); return $res->finalize; }
    # Permanently delete LIST nn and redirect to lists page
    if ($req->path =~ m{^/list_hard_delete/(\d+)$})     { action_list_hard_delete($1);  $res->redirect('/lists'); return $res->finalize; }
    # Set a LIST as the default list
    if ($req->path =~ m{^/list_set_default/(\d+)$})     { action_list_set_default($1);  $res->redirect('/lists'); return $res->finalize; }
    # Set all tasks in LIST nn as Active
    if ($req->path =~ m{^/list_set_alltasks_active/(\d+)$})         { action_list_set_alltasks_active($1);      $res->redirect('/lists'); return $res->finalize; }
    # Set all tasks in LIST nn as Completed
    if ($req->path =~ m{^/list_set_alltasks_completed/(\d+)$})      { action_list_set_alltasks_completed($1);   $res->redirect('/lists'); return $res->finalize; }
    # Permanently delete all tasks in LIST nn
    if ($req->path =~ m{^/list_harddelete_alltasks/(\d+)$})         { action_list_harddelete_alltasks($1);      $res->redirect('/lists'); return $res->finalize; }
    # Change a list from active to archived
    if ($req->path =~ m{^/list_archive/(\d+)$})     { action_list_archive($1);  $res->redirect('/lists'); return $res->finalize; }

    ###############################################
    # !SHOW functions
    # Show the settings page
    if ($req->path eq "/settings")                           { $res->body(show_settings());             return $res->finalize; }
    # Show a page with all lists and tasks
    if ($req->path eq '/show_tasks_all')                     { $res->body(show_tasks_all());            return $res->finalize; }
    # Show a page with all recurring tasks
    if ($req->path eq '/show-recurring')                     { $res->body(show_tasks_recurring());      return $res->finalize; }
    # Stats page - show calculated statistics
    if ($req->path eq "/stats")                              { $res->body(show_stats());                return $res->finalize; }
    # Show /lists page with all lists and management options
    if ($req->path eq "/lists")                              { $res->body(show_lists());                return $res->finalize; }
    # Main landing page, the current task list
    if ($req->path eq "/" )                                  { $res->body(show_maintasks());            return $res->finalize; }
    # Show the edit list form (from /lists page)
    if ($req->path =~ m{^/list_edit/(\d+)$})                 { $res->body(show_list_edit($1,1));          return $res->finalize; }
    # As above, but from the task list page, so we can redirect back there after submission
    if ($req->path =~ m{^/list_edit_fromtask/(\d+)$})                 { $res->body(show_list_edit($1,2));          return $res->finalize; }

    ###############################################
    # !RECEIVE functions
    # Receive edit task form. No output, redirect to root
    if ($req->path =~ m{^/task_form_edit/(\d+)$})            { receive_form_task_edit($1, $req);   $res->redirect('/');  return $res->finalize; }
    # Receive add task form. No output, redirect to root
    if ($req->path eq "/task_form_add")                      { receive_form_task_add($req);  $res->redirect('/');  return $res->finalize; }
    # Receieve settings form submission
    if ($req->path eq "/settings_form")                      { receive_settings($req);    $res->redirect('/settings'); return $res->finalize; }
    # Receive background image upload form submission
    if ($req->path eq '/settings_background_form')           { receive_settings_background($req); $res->redirect('/settings'); return $res->finalize; }

    # Receive Lists form (Variable redirect page if came from /lists or /)
    if ($req->path =~ m{^/list_form/(\d+)$})                 {
            receive_form_list($req, $1);
            my $list_edit_return_pagevalue = $req->param('return_page') // 1;
            debug("Received list form submission for list id $1, return_page value is $list_edit_return_pagevalue");
            if ($list_edit_return_pagevalue == 2) { $res->redirect(('/')); }  # Return to active list page if came from there
            else { $res->redirect('/lists'); }
            return $res->finalize;
            }

    ###############################################
    # !MISC functions

    # /api/ping check - suitable for health checks
    if ($req->path eq "/api/ping")     { $res->header('Content-Type' => 'text/plain');  $res->header('Cache-Control' => 'no-cache, no-store');  $res->body('pong');  return $res->finalize;  }

    # /api/dbstate check - returns simple JSON with last mtime of the database
    if ($req->path eq "/api/dbstate") {  update_db_mtime();  $res->header('Content-Type' => 'text/plain'); $res->header('Cache-Control' => 'no-cache, no-store'); $res->body($page->{'db_mtime'}); return $res->finalize; }

    # End path redirectors
    ###############################################
    # If we got here, no path matched. Show a 404 to STDERR and return a 404 page to the client
    show_404($req->path);
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
    if (! -e $global->{'db_path'}) {
        # Database file does not exist, so create it and initialise it.
        print STDERR "Database file $global->{'db_path'} not found. Assuming new install and creating new database\n";
        # Ensure data directory exists
        my ($data_dir) = $global->{'db_path'} =~ m{^(.*)/[^/]+$};

        if (! -d $data_dir) {
            print STDERR "Data directory $data_dir does not exist, creating it now.\n";
            mkdir $data_dir or print STDERR "FATAL: Inability to create data directory $data_dir to create the database file, $global->{'db_path'}\n";

            if (! -d $data_dir) {
                print STDERR "I tried to create the data directory $data_dir but it still does not exist. Cannot continue.\n";
                exit 1;
                }
            }

        print STDERR "----------------------------------------------------\n";
        print STDERR "Welcome to $global->{'app_title'}!\n";
        print STDERR "----------------------------------------------------\n\n";

        # Create new database connection which will autocreate the new database file
        $dbh = DBI->connect("dbi:SQLite:dbname=$global->{'db_path'}", "", "", {
            RaiseError => 1,
            AutoCommit => 1,
            }) or die $DBI::errstr;

        initialise_database();  # Create tables etc.

        } else {
        print STDERR "Database file $global->{'db_path'} found, connecting to existing database.\n";

        # The database does exist, so connect to it.
        $dbh = DBI->connect("dbi:SQLite:dbname=$global->{'db_path'}", "", "", {
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
        (2, 'Default List', 'Main day to day list', 1)
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
    # Check database_schema_version in ConfigTb and compare to this script's $global->{'database_schema_version'}  - assume v.1 if it's missing
    my $current_db_version = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'database_schema_version' LIMIT 1") || 1;

    if ($current_db_version < $global->{'database_schema_version'}) { # If current is lower than required, we need to upgrade
        print STDERR "INFO: Database schema version is $current_db_version - $global->{'app_title'} requires schema $global->{'database_schema_version'}.\n";

        if ($current_db_version == 1) {
            ###############################################
            # Add schema step changes here, v.1 to v.2
            print STDERR "Upgrading database schema from version 1 to version 2.\n";

            # List of queries required to upgrade from v.1 to v.2
            my @db_upgrade_steps_1_to_2 = (
                "UPDATE ListsTb SET Title = 'All Tasks' WHERE Title = 'All Lists';",                # Change name of 'All Lists' to 'All Tasks'
                "ALTER TABLE TasksTb ADD COLUMN IsRecurring TEXT DEFAULT 'off';",                   # New column to indicate whether task is recurring
                "ALTER TABLE TasksTb ADD COLUMN RecurringIntervalDay INTEGER DEFAULT 1;",           # New column to indicate recurring interval in days
                "UPDATE ConfigTb SET `value` = '2' WHERE `key` = 'database_schema_version';",       # Update version number in ConfigTb
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

        # !! Add future db v.2 to v.3 upgrade steps here !!

        } else {
        print STDERR "Database schema version is up to date at version $current_db_version. Required version is $global->{'database_schema_version'}. We're good.\n";
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
    <title>$global->{'app_title'} / $page->{'list_name'}</title>

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
        .icon-white { filter: brightness(0) invert(1); }
        .icon-highlight { filter: brightness(1.2) saturate(1.5); }

        /* Improved tooltip styling */
        .tooltip-inner {
            background-color: #1A2122;
            border: 3px solid #ffffff;
            border-radius: 8px;
            padding: 12px 18px;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
            box-shadow: 0 4px 12px rgba(0,0,0,0.4);
            max-width: 450px;
            font-size: 17.5px;
            line-height: 1.2;
        }

        .tooltip-arrow::before {
            border-top-color: #1A2122;
        }

        .bs-tooltip-top .tooltip-arrow::before,
        .bs-tooltip-bottom .tooltip-arrow::before {
            border-top-color: #1A2122;
        }

        .bs-tooltip-start .tooltip-arrow::before,
        .bs-tooltip-end .tooltip-arrow::before {
            border-left-color: #1A2122;
        }

        .card-header-accent::before {
            content: "";
            position: absolute;
            top: 0;
            right: 0;
            width: 0;
            height: 0;
            border-top: 40px solid $page->{'list_colour'};
            border-left: 40px solid transparent;
        }

        .card-header-accent {
            position: relative;
            overflow: hidden;
        }

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
                <a href="/list/$page->{'default_listid'}" class="d-flex align-items-center gap-2 text-white text-decoration-none"
                data-bs-toggle="tooltip" data-bs-placement="auto" title="Switch to Default List" >
                    <img src="/static/$global->{'taskpony_icon'}" width="82" height="82" alt="logo">
                </a>
                <a href="/" class="d-flex align-items-center gap-2 text-white text-decoration-none"
                data-bs-toggle="tooltip" data-bs-placement="auto" title="Home - Show active tasks in '$page->{'list_name'}'"
                >
                    <h3 class="mb-0">$global->{'app_title'}</h3>
                </a>
                ~;

    # Add the list selection pulldown.
    $html .= list_pulldown($page->{'list_id'});


    # Start the top-right button group
    $html .= qq~
                    </div>
            ~;

    # If configured, show to quickswitcher
    $html .= show_quickswitcher();

    $html .= qq~
                    <div class="btn-group" role="group">
            ~;

    # Show completed/active button
    if ($page->{'show_completed'} == 0) {  # We're on the active tasks page, so show button for completeds
                my $cnt_completed_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 2 AND ListId = $page->{'list_id'}");
                if ($page->{'list_id'} == 1) {
                    $cnt_completed_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 2");
                    }
                $html .= qq~
                <a href="/?sc=1"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Show $cnt_completed_tasks completed tasks in '$page->{'list_name'}'" >
                    $icons->{'rotate_left'}
                </a>
                ~;
                } else { # We're showing completed tasks, so show button for the active list
                my $cnt_active_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 1 AND ListId = $page->{'list_id'}");
                if ($page->{'list_id'} == 1) {
                    $cnt_active_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 1");
                    }
                $html .= qq~
                <a href="/"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Show $cnt_active_tasks active tasks in '$page->{'list_name'}'" >
                    $icons->{'rotate_right'}
                </a>
                ~;
                } # End active/completed button

                $html .= qq~
                <a href="/lists"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Manage Lists" >
                    $icons->{'list'}
                </a>

                <a href="/stats"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center justify-content-center btn-icon"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Statistics" >
                    $icons->{'chart'}
                </a>

                <a href="/settings"
                    class="btn btn-sm btn-$config->{'cfg_header_colour'} d-inline-flex align-items-center justify-content-center btn-icon"
                    data-bs-toggle="tooltip" data-bs-placement="auto" title="Settings" aria-label="Settings">
                    $icons->{'gear'}
                </a>

            </div>
        </div>
<!-- End header() -->
    ~;

    return $html;
    } # End header()

###############################################
# Return standard HTML footer for all pages
# Close 3x divs opened from header()
sub footer {
    my $html = show_alert();  # If there is an alert in ConfigTb waiting to be shown, display it above the footer.

    $html .= qq~
        <!-- Footer -->
                    </div>
                </div>
            </div>
        </main>
        <footer class="text-center text-white-50 py-2">
            <p>
            ~;

    # Show label for a new version if it exists
    if ( ($config->{cfg_version_check} eq 'on') && ($global->{'new_version_available'} == 1 ) ) {
        $html .= qq~
            <span class="badge rounded-pill  bg-$config->{cfg_header_colour}">
                <a href="$global->{'app_releases_page'}" class="text-white text-decoration-none" target="_blank">
                    New version available
                </a>
            </span>
            &nbsp;
        ~;
        }

    $html .= qq~
            <a href="https://github.com/digdilem/taskpony" class="text-$config->{cfg_header_colour} text-decoration-none">$global->{'app_title'} v.$global->{'app_version'}</a> by <a href="https://digdilem.org/" class="text-$config->{cfg_header_colour} text-decoration-none">Digital Dilemma</a>
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
                    \$('#tasktitle').focus();
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
        <!-- End DataTables setup -->

        <script>
        \$(document).ready(function(){
        \$('[data-bs-toggle="tooltip"]').tooltip({
            delay: { $global->{'tooltip_delay'} }
        });
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
        <!-- End Footer() -->
        ~;

    return $html;
    } # End footer()

###############################################
# list_pulldown($selected_lid)
# Returns HTML for a pulldown list of available lists, with the selected list marked as selected
sub list_pulldown {
    my $selected_lid = shift || $page->{'list_id'};

    # Redirect to root with /list/<id> when selection changes (no enclosing form required)
    my $html = qq~
        <select name="lid"
            class="form-select form-select-sm" style="width:auto; display:inline-block; margin-left:10px;" onchange="window.location='/list/' + encodeURIComponent(this.value)">
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
    $s =~ s/\r\n/\n/g;            # normalize line endings
    $s =~ s/[^\n\t[:print:]]+//g;   # remove non-printables (but keep newlines)
    $s =~ s/^\s+|\s+$//g;         # trim
    return $s;
    } # End sanitize()

sub html_escape {
    # html_escape($s)
    # Escape HTML special characters in a string
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
    } # End html_escape()

sub html_escape_with_breaks {
    # html_escape_with_breaks($s)
    # Escape HTML special characters and convert newlines to <br> tags for display
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    $s =~ s/\n/<br>/g;  # Convert newlines to HTML breaks
    return $s;
    } # End html_escape_with_breaks()

sub single_db_value {
    # single_db_value($sql, @params)
    # Execute a SQL query that returns a single value
    my ($sql, @params) = @_;
    debug("Executing single_db_value with SQL: $sql and params: " . join(', ', @params));
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my ($value) = $sth->fetchrow_array();
    return $value;
    } # End single_db_value()

sub debug {
    # debug($msg)
    # Print debug message if debugging is globally enabled
    my $msg = shift;
    if ($global->{'debug'} == 1) {
        print STDERR "DEBUG: $msg\n";
        }
    } # End debug()

###############################################


###############################################


###############################################


###############################################


###############################################


###############################################


###############################################

###############################################


###############################################


###############################################


###############################################


###############################################


###############################################


###############################################



###############################################
# SHOW functions - Functions that show html

sub show_tasks_all {    # Loop through all active lists and show a panel for each with the tasks in that list.
    my $html = header();

    my $lists_sth = $dbh->prepare("SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL AND id != 1 ORDER BY Title ASC");
    $lists_sth->execute();

    while (my $list = $lists_sth->fetchrow_hashref()) {
        $html .= start_card($list->{'Title'}, '', 0);
        $html .= show_tasks(1, $list->{'id'}, 1);  # Show active tasks for this list, not hidden
        $html .= end_card(0);
        }

    $html .= footer();
    return $html;
    } # End show_tasks_all()

sub build_tabler_icon { # build_tabler_icon($icon_name) = takes the Name of the SVG file, which matches its Alt Text
    my ($icon_name) = @_;
    return qq~<img src="/static/icons/$icon_name.svg" alt="$icon_name" class="icon-white" />~;
    } # end build_tabler_icon

sub build_inline_icon {  # build_inline_icon($size, $svg) = takes a size in pixels and raw SVG code, and returns the SVG wrapped in a span with the correct size styling to make it match the text size
    my ($size, $svg) = @_;

    return qq~<span style="font-size: ~ . $size . qq~px; line-height:1;">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon">$svg</svg>
        </span>~;
    } # end build_inline_icon

sub config_show_option { # config_show_option($key, $title, $description, $type (check, number, colour), $num_range_lower, $numrange_upper); Output a line of a setting  for /settings   forms
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

sub start_card { # start_card() Open a consistent bootstrap 5 card for most pages. # Takes a title and optional icon HTML to show in the header.
    # If $table_card is set to 1, it will add an id to the card that allows it to be hidden until the datatable is fully loaded, which reduces flicker.
    # Opens 2 divs, or 3 if table_card is set, but does not close them. Call end_card() to close the divs.
    my $card_title = shift || 'Title Missing';
    my $card_icon = shift || '';
    my $table_card = shift || 0;  # If 1, forces a reload after datatables to reduce flicker

    my $html = qq~
    <!-- start_card($table_card) $card_title -->
    <!-- ############################################################################################## -->
            <div class="card shadow-sm mb-4">
            ~;

    if ($table_card == 1) { $html .= qq~ <div class="card shadow-sm d-none " id="hideUntilShow" >~; }  # If a table, hide the whole card until loaded. div will be closed eith end_card(1)

    $html .= qq~
                <div class="card-header bg-$config->{cfg_header_colour} text-white">
                ~;

    # if (length $page->{'list_colour'} > 2) {  # This list has a highlight colour override, use it
    #     $html .= qq~<div class="card-header text-white" style="background-color:$page->{'list_colour'};">~;
    #     } else { # Show default bg-
    #$html .= qq~ ~;
        # }

    my $show_accent_string = "card-header-accent";
    if (! $page->{'list_colour'} ) { $show_accent_string = " "; } # This list has no override set, so don't show the accent triangle

    $html .= qq~
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
                    <div class="card-body $show_accent_string bg-dark text-white rounded-bottom">
    <!-- End start_card() header -->
                    ~;
    return $html;
    } # End start_card()

sub end_card {  # end_card($is_table_card) - Close a card previously opened with start_card(). If $is_table_card is 1, it will also close the div that hides the card until datatables is loaded, and add a script to show the card once datatables is loaded.
    my $html = "<!-- Start end_card() -->\n";
    my $table_card = shift || 0;
    if ($table_card == 1) { $html = qq~                            </div>  <!-- End hideUntilShow div for the table -->~; }  # Close the div that hides the card until datatables is loaded
    $html .= qq~
                </div>
            </div>
            <!-- close end_card() ############################################################################################## -->
                ~;
    return $html;
    } # End end_card()

sub add_alert { # add_alert($page->{'alert_text'}) - Store an alert message in ConfigTb to be shown on next page load
    my $page->{'alert_text'} = shift;
    $dbh->do(
        "INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?;",
        undef,
        'last_alert',
        $page->{'alert_text'},
        $page->{'alert_text'}
        ) or print STDERR "Failed to set last_alert: " . $dbh->errstr;
    } # End add_alert()

sub show_alert { # show_alert() - Check ConfigTb for last_alert and if found, show it once and clear it
    my $page->{'alert_text'} = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'last_alert' LIMIT 1");

    if ($page->{'alert_text'}) { # There is an alert pending
        single_db_value("DELETE FROM ConfigTb WHERE `key` = 'last_alert'");

        return qq~
        <div class="row g-3 mb-2">
            <div class="col-md-3"></div>
            <div class="col-md-6">
                <div id="alert1" class="alert alert-success alert-dismissible fade show" role="alert">
                $page->{'alert_text'}
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

sub show_tasks { # show_tasks($status, $page->{'list_id'}, $not_hidden, $show_recurring)
    # Return HTML table of tasks with given status (1=active,2=completed) for given list_id (1=all lists)
    # If $show_recurring is 1, shows all recurring tasks regardless of status

    my ($status, $list_id_param, $not_hidden, $show_recurring) = @_;
    $page->{'list_id'} = $list_id_param;
    $show_recurring = $show_recurring // 0;  # Default to 0 if not provided

    # Build SQL query
    my $sql = "
        SELECT t.id, t.Title, t.Description, t.AddedDate, t.CompletedDate, t.ListId, t.IsRecurring, t.RecurringIntervalDay, p.Title AS ListTitle
        FROM TasksTb t
        LEFT JOIN ListsTb p ON t.ListId = p.id
        WHERE 1=1
        ";

    my @params;  # Array to hold parameters for the query

    if ($show_recurring == 1) {
        # Show all recurring tasks regardless of status
        $sql .= " AND t.IsRecurring = 'on' ";
        debug("show_tasks: Showing all recurring tasks");
        } else {
        # Show tasks by status
        $sql .= " AND t.Status = ? ";
        push @params, $status;
        }

    if ($page->{'list_id'} != 1 && $show_recurring != 1) {  # list_id is 1, which means ALL lists. If it's not 1, then filter by list_id
        $sql .= " AND t.ListId = $page->{'list_id'} ";
        debug("show_tasks: Filtering tasks for list_id: [$page->{'list_id'}]");
        } else {
        if ($show_recurring != 1) {
            debug("show_tasks: Showing tasks for ALL lists");
            }
        }

    # Append ordering and finish query. If showing recurring, sort by interval and title. Otherwise, sort by date
    if ($show_recurring == 1) {
        $sql .= " ORDER BY t.RecurringIntervalDay ASC, t.Title ASC ";
        } elsif ($status == 2) {
        $sql .= " ORDER BY t.CompletedDate DESC ";
        } else {
        $sql .= " ORDER BY t.AddedDate DESC ";
        }

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my $hidden_string = 'dt-hidden';
    if ($not_hidden == 1) { $hidden_string = ''; }  # Don't be smart if we're explicitly told not to be, such as displaying multiple lists

    my $html = qq~
        <!-- Start show_tasks() -->
        <table id="tasks" class="display hover table-striped $hidden_string mb-3" style="width:90%">
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

    ###############################################
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
        my $description = html_escape_with_breaks(substr($a->{'Description'},0,$config->{'cfg_description_short_length'}));
        my $title = html_escape($a->{'Title'});
        my $list_title = substr(html_escape($a->{'ListTitle'} // 'Unknown'),0,$config->{cfg_list_short_length});

        ###############################################
        # Check to see whether the List this task belongs to is deleted and if so, show it as being orphaned

        my $list_deleted = single_db_value("SELECT COUNT(*) FROM ListsTb WHERE id = ? AND DeletedDate IS NOT NULL", $a->{'ListId'}) // 0;
        if ($list_deleted != 0) { # List is deleted, this task is an orphan
            $list_title = '[--No List--]';

            # Prefix task title with an orphaned marker, coloured red
            $title_link .= qq~<span class="text-$config->{cfg_header_colour}" data-bs-toggle="tooltip" data-bs-placement="auto" title="This task belongs to a deleted list">
                $smallicons->{'link'}_slash
            </span>
            ~;
            }

        # Add a repeat icon if the task is recurring
        if (defined $a->{'IsRecurring'} && $a->{'IsRecurring'} eq 'on') {
            $title_link .= qq~<span class="text-$config->{cfg_header_colour}" data-bs-toggle="tooltip" data-bs-placement="auto" title="This is a repeating task. Once completed, it will reactivate after $a->{RecurringIntervalDay} days">
                $smallicons->{'repeat'}
            </span> ~;
            }

        # Show Active tasks. Show checkbox to mark complete
        if ($status == 1) {
            $checkbox = qq~
                <a href="/task_complete/$a->{'id'}" class="btn btn-sm btn-outline-$config->{cfg_header_colour} m-0" title="Mark Task as Completed">✓</a>
                ~;

            $title_link .= qq~
                    <a
                    href="/task_edit/$a->{'id'}"
                    class="text-white text-decoration-none"
                    data-bs-toggle="tooltip" data-bs-placement="auto"
                    data-bs-html="true"
                    title="$description">
                        $title
                    ~;
            if ($description) {
                $title_link .= qq~<span class="text-$config->{cfg_header_colour}">&nbsp; $smallicons->{'comment'}
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
                    href="/task_edit/$a->{'id'}"
                    class="text-white text-decoration-none"
                    data-bs-toggle="tooltip" data-bs-placement="auto"
                    title="$description Completed ~ . human_friendly_date($a->{'CompletedDate'}) . qq~">
                        <span class="opacity-50">$title</span>
                    </a>
                     ~;

            $checkbox .= qq~
                <a href="/task_activate/$a->{'id'}" class="btn btn-sm btn-outline-$config->{cfg_header_colour} m-0" title="Mark Task as Active">$icons->{'rotate_left'}</a>
                ~;
            }

        # Recurring tasks view - show title with status indicator
        if (defined $show_recurring && $show_recurring == 1) {
            my $status_indicator = '';
            if (defined $a->{'Status'} && $a->{'Status'} == 1) {
                $status_indicator = '(Active)';
                } elsif (defined $a->{'Status'} && $a->{'Status'} == 2) {
                $status_indicator = '(Completed)';
                }

            $title_link .= qq~
                    <a
                    href="/task_edit/$a->{'id'}"
                    class="text-white text-decoration-none"
                    data-bs-toggle="tooltip" data-bs-placement="auto"
                    data-bs-html="true"
                    title="$description">
                        <span class="badge rounded-pill bg-secondary">$a->{RecurringIntervalDay}</span>
                        $title <span class="text-muted small">$status_indicator</span>
                    ~;
            if ($description) {
                $title_link .= qq~<span class="text-$config->{cfg_header_colour}">&nbsp; $smallicons->{'comment'}
                </span>
                ~;
                }
            $title_link .= qq~
                    </a>
                     ~;
            }

        ###############################################
        # Output the table row
        ###############################################
        $html .= qq~
            <!-- Task row -->
            <tr>
                <!-- Checkbox / Undo button -->
                <td style="text-align: center;">$checkbox</td>
                <!-- Title Link -->
                <td>$title_link
                </td>
                ~;

        ###############################################
        # Show or hide date and list column header based on config var cfg_show_dates.
        if ($config->{'cfg_show_dates'} eq 'on') {
            $html .= qq~
                    <!-- Date column -->
                    $friendly_date
                    <!-- End Date column -->
                ~;
            }

        ###############################################
        # Show or hide date and list column header based on config var cfg_show_dates_lists
        if ($config->{'cfg_show_lists'} eq 'on') {
            $html .= qq~
                    <!-- List column -->
                    <td>
                    ~;
            if ($list_deleted != 0) { # List is deleted, no link
                $html .= qq~
                        $list_title
                    </td>
                    ~;
                } else {
                $html .= qq~
                        <a
                        href="/list/$a->{'ListId'}"
                        class="text-$config->{'cfg_header_colour'} text-decoration-none"
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
             <!-- End show_tasks() -->
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
        let lastValue = Number($page->{'db_mtime'});

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
                window.location.href = '/';
            }
            } catch (e) {
            // Fail silently
            }
        }

        setInterval(checkDbStats, $page->{'db_interval_check_ms'});
        })();
        </script> <!-- End DB stats check script -->

        <!-- Gutter of show_tasks() card -->

        <!-- Show Gutter Lefthand side for local choices -->
        <span class="float-start muted d-flex gap-3">

            <!-- Show permanent link to this list -->
            <a href="/list/$page->{'list_id'}" class="text-$config->{'cfg_header_colour'} text-decoration-none"
            data-bs-toggle="tooltip" data-bs-placement="auto"
            title="Permanent link to this list">
                $smallicons->{'link'}
            </a>
        ~;

        if ($page->{'list_id'} != 1) {  # Not "All lists", so show link to add task to this list
            $html .= qq~
            <a href="/list_edit_fromtask/$page->{'list_id'}" class="text-$config->{'cfg_header_colour'} text-decoration-none"
            data-bs-toggle="tooltip" data-bs-placement="auto"
            title="Edit this list">
                $smallicons->{'edit'}
            </a>

            <a href="/task_add" class="text-$config->{'cfg_header_colour'} text-decoration-none"
            data-bs-toggle="tooltip" data-bs-placement="auto"
            title="Add a new task">
                $smallicons->{'plus'}
            </a>
            ~;
            }

        $html .= qq~
        </span>

        <!-- Show Gutter Righthand side -->
        <span class="float-end muted d-flex gap-3">
            <!-- Show link to all tasks in all lists -->
            <a href="/show_tasks_all" class="text-$config->{'cfg_header_colour'} text-decoration-none"
                data-bs-toggle="tooltip" data-bs-placement="auto"
                title="Show all active tasks in lists">
                $smallicons->{'listnumbers'}
            </a>

            <!-- Show link to recurring tasks -->
            <a href="/show-recurring" class="text-$config->{'cfg_header_colour'} text-decoration-none"
                data-bs-toggle="tooltip" data-bs-placement="auto"
                title="Show recurring tasks">
                $smallicons->{'repeat'}
            </a>
            ~;

        $html .= qq~
        </span>
        <!-- End footer of show_tasks() card -->

        ~;

    return $html;
    } # End show_tasks()

sub show_stats { # show_stats() - Show various stats about the tasks and lists in a table format
    my $html = header();
    $html .= start_card('Statistics', $icons->{'chart'}, 0);

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
                    Database schema version: <strong class="text-white">$config->{'database_schema_version'}</strong> Required: <strong class="text-white">$global->{'database_schema_version'}</strong>
                </span>
            </li>
            <li>
                <span class="pt-3 small text-white-50">~;
                    if ($global->{'running_in_docker'} == 1) {
                        $html .= qq~Running inside Docker ~;
                        } else {
                        $html .= qq~Running on host as a native service ~;
                        }
                    $html .= qq~
                </span>
            </li>
            <li>
                <span class="pt-3 small text-white-50">
                    Database path: <strong class="text-white">$global->{'db_path'}</strong>
                </span>
            </li>
            <li>
                <span class="pt-3 small text-white-50">
                    Background image path: <strong class="text-white">$global->{'bg_path'}</strong>
                </span>
            </li>
        </ul>
    </div>
    ~;

    $html .= end_card(0);
    $html .= footer();
    return $html;
    } # End /stats

sub show_tasks_recurring { # show_tasks_recurring() - Show all recurring tasks in a single table, regardless of list or status, with an indicator of their status and interval
    my $html = header();
    $html .= start_card('Recurring Tasks', $icons->{'repeat'}, 1);
    $html .= show_tasks(0, 0, 1, 1);  # status=0 (all), list_id=0 (all), not_hidden=1, show_recurring=1
    $html .= end_card(1);
    $html .= footer();
    return $html;
    }

sub show_lists { # show_lists() - Show all lists with stats on how many active and completed tasks in each, and links to view each list, edit the list, and add a task to the list
    my $html = header();

    # Page - Display List of Lists #List
    ###############################################
    $html .= "<!-- Lists Management Tabs -->\n";

    # Build the tab navigation
    $html .= qq~
            <ul class="nav nav-tabs mb-4" id="listsTabs" role="tablist">
                <li class="nav-item" role="presentation">
                    <button class="nav-link active" id="active-lists-tab" data-bs-toggle="tab" data-bs-target="#active-lists" type="button" role="tab" aria-controls="active-lists" aria-selected="true">Active Lists</button>
                </li>

                <li class="nav-item" role="presentation">
                    <button class="nav-link" id="archived-lists-tab" data-bs-toggle="tab" data-bs-target="#archived-lists" type="button" role="tab" aria-controls="archived-lists" aria-selected="false">Archived Lists</button>
                </li>
                <li class="nav-item" role="presentation">
                    <button class="nav-link" id="list-actions-tab" data-bs-toggle="tab" data-bs-target="#list-actions" type="button" role="tab" aria-controls="list-actions" aria-selected="false">List Actions</button>
                </li>
            </ul>

    <div class="tab-content" id="listsTabContent">
        <!-- Active Lists Tab -->
        <div class="tab-pane fade show active" id="active-lists" role="tabpanel" aria-labelledby="active-lists-tab">
        <div class="card bg-dark text-white">
            <div class="card-header bg-$config->{'cfg_header_colour'} text-white d-flex align-items-center gap-2">
                <span>$icons->{'list'} Active Lists</span>
                <div class="ms-auto"><a href="/list_edit/0" class="text-white text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Create a New List">$icons->{'plus'}</a></div>
            </div>
            <div class="card-body">
            <div class="table-responsive">
                <table class="table table-dark table-striped">
                <thead>
                    <tr>
                    <th>List</th>
                    <th>Description</th>
                    <th class="text-end">Tasks</th>
                    <th class="text-end">Actions</th>
                    </tr>
                </thead>
                <tbody>
    ~;

    # Add "All Tasks Lists" row
    my $all_active = single_db_value('SELECT COUNT(*) FROM TasksTb WHERE Status = 1') // 0;
    my $all_completed = single_db_value('SELECT COUNT(*) FROM TasksTb WHERE Status = 2') // 0;

    $html .= qq~
                    <tr>
                    <td>
                        <strong>
                        <a href="/list/1"  class="text-white text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Show all Active Tasks">
                            All Tasks
                        </a>
                        </strong>
                    </td>
                    <td>
                        View tasks from all lists
                    </td>
                    <td align="right">
                        <a href="/list/1" class="text-white text-decoration-none" data-bs-placement="auto" title="Show all Active Tasks">
                        $all_active
                        </a> /
                        <a href="/list/1?sc=1" class="text-white text-decoration-none" data-bs-placement="auto" title="Show all Completed Tasks">
                        $all_completed
                        </a>
                    </td>
                    <td>
                        &nbsp;
                    </td>
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
        my $desc = substr(html_escape($list->{'Description'} // ''), 0, $config->{'cfg_description_short_length'});

        $html .= qq~
                    <tr>
                    <td>
                        <strong>
                        <span data-bs-toggle="tooltip" data-bs-placement="auto" title="Jump to List"><a class="text-white text-decoration-none" href="/list/$list->{'id'}">
                            $title
                        </a>
                        </span>
                        </strong>
                    </td>
                    <td>
                        $desc
                    </td>
                    <td align="right">
                        <a href="/list/$list->{'id'}" class="text-white text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Jump to $title">
                            $active_count
                        </a> /
                        <a href="/list/$list->{'id'}?sc=1" class="text-white text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Jump to completed tasks for $title">
                            $completed_count
                        </a>
                    </td>
                    <!-- Actions column -->
                    <td class="text-end">
                        <div class="btn-group" role="group">
                            <!-- Edit Button -->
                            <a href="/list_edit/$list->{'id'}"
                            class="btn btn-sm  d-inline-flex align-items-center justify-content-center btn-icon"
                            data-bs-toggle="tooltip" data-bs-placement="auto" title="Edit this List" >
                                $icons->{'edit'}
                            </a>
                            <!-- Default Button -->
                            <a href="/list_set_default/$list->{'id'}"
                            class="btn btn-sm  d-inline-flex align-items-center justify-content-center btn-icon"
                            data-bs-toggle="tooltip" data-bs-placement="auto" title="Set this as the Default List" >
                                ~;
                                if ($list->{'IsDefault'} == 1) {
                                    $html .= $icons->{'star_on'};
                                    } else {
                                    $html .= $icons->{'star_off'};
                                    }
                                $html .= qq~
                            </a>
                            <!-- Set all tasks Active Button -->
                            <a href="/list_set_alltasks_active/$list->{'id'}"
                            class="btn btn-sm  d-inline-flex align-items-center justify-content-center btn-icon"
                            data-bs-toggle="tooltip" data-bs-placement="auto" title="Set all Tasks in this List as Active"
                            onclick="return confirm('Are you sure you want to set ALL tasks in this list as Active?');">
                                $icons->{'rotate_right'}
                            </a>
                            <!-- Set all tasks Completed Button -->
                            <a href="/list_set_alltasks_completed/$list->{'id'}"
                            class="btn btn-sm  d-inline-flex align-items-center justify-content-center btn-icon"
                            data-bs-toggle="tooltip" data-bs-placement="auto" title="Set all Tasks in this List as Completed"
                            onclick="return confirm('Are you sure you want to mark ALL tasks in this list as Completed?');">
                                $icons->{'rotate_left'}
                            </a>
                            <!-- Set List as Archived -->
                            <a href="/list_archive/$list->{'id'}" class="btn btn-sm btn-outline-danger d-inline-flex align-items-center justify-content-center btn-icon"
                            data-bs-toggle="tooltip" data-bs-placement="auto" title="Set this List as Archived. This will hide the list and its tasks from the main view, but they can be restored later if needed. Tasks will still appear in the 'All Tasks' view"
                            onclick="return confirm('Are you sure you want to archive this list?');">
                                $icons->{'sleep'}
                            </a>
                        </div>
                    </td>
                    <!-- End Actions column -->
                    </tr>
        ~;
        } # End lists loop

    $html .= qq~
                </tbody>
                </table>
            </div> <!-- Close table responsive div -->
            </div>
        </div>
        </div>



        <!-- Archived Lists Tab -->
        <div class="tab-pane fade" id="archived-lists" role="tabpanel" aria-labelledby="archived-lists-tab">
        <div class="card bg-dark text-white">
            <div class="card-header bg-$config->{'cfg_header_colour'} text-white d-flex align-items-center gap-2">
            <span>$icons->{'sleep'}</span>
            <span>Archived Lists <a href=# class="text-white text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="auto" title="Lists that have been set as Archived. You can choose to restore these lists or permanently delete them">$icons->{'info'}</a></span>
            </div>
            <div class="card-body">
            <div class="table-responsive">
                <table class="table table-dark table-striped">
                <thead>
                    <tr>
                    <th>List</th>
                    <th>Deleted Date</th>
                    <th>Tasks</th>
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
        my $tasks_in_list = single_db_value(
            'SELECT COUNT(*) FROM TasksTb WHERE ListId = ?',
            $a->{'id'}
            ) // 0;

        $html .= qq~
                    <tr>
                    <td>
                        <strong>
                        $title
                        </strong>
                    </td>
                    <td>
                        $a->{'DeletedDate'}
                    </td>
                    <td>
                        $tasks_in_list
                    </td>
                    <!-- Actions column -->
                    <td class="text-end">
                        <div class="btn-group" role="group">
                        <!-- Default Button -->
                        <a href="/list_unarchive/$a->{'id'}"
                        class="btn btn-sm d-inline-flex align-items-center justify-content-center btn-icon"
                        data-bs-toggle="tooltip" data-bs-placement="auto" title="Unarchive this list" >
                            $icons->{'rotate_right'}
                        </a>
                        <!-- Delete all Tasks -->
                        <a href="/list_harddelete_alltasks/$a->{'id'}"
                        class="btn btn-sm btn-outline-danger d-inline-flex align-items-center justify-content-center btn-icon"
                        data-bs-toggle="tooltip" data-bs-placement="auto" title="Permanently delete all $tasks_in_list tasks within this List"
                        onclick="return confirm('Are you sure you want to PERMANENTLY delete ALL tasks in this list?');">
                            $icons->{'xcircle'}
                        </a>
                        <!-- Permanently delete this List -->
                        <a href="/list_hard_delete/$a->{'id'}"
                        class="btn btn-sm btn-outline-danger d-inline-flex align-items-center justify-content-center btn-icon"
                        data-bs-toggle="tooltip" data-bs-placement="auto" title="Permanently delete this List"
                        onclick="return confirm('Are you sure you want to PERMANENTLY delete this list?  Any tasks within this list will be orphaned.');">
                            $icons->{'grave'}
                        </a>
                        </div>
                    </td>
                    <!-- End Actions column -->
                    </tr>
        ~;
        } # End archived lists loop
    $html .= qq~
                </tbody>
                </table>
            </div>
            </div>
        </div>
        </div>

        <!-- List Actions Tab -->
        <div class="tab-pane fade" id="list-actions" role="tabpanel" aria-labelledby="list-actions-tab">
        <div class="card bg-dark text-white">
            <div class="card-header bg-$config->{'cfg_header_colour'} text-white d-flex align-items-center gap-2">
            <span>$icons->{'list'}</span>
            <span>List Actions</span>
            </div>
            <div class="card-body">
            <p>
                <a href="/show_tasks_all" class="btn btn-outline-light" data-bs-toggle="tooltip" data-bs-placement="auto" title="View all tasks from all lists on a single, sorted page">
                $icons->{'list'}Show All Tasks
                </a>
            </p>
            <p>
                <a href="/show-recurring" class="btn btn-outline-light" data-bs-toggle="tooltip" data-bs-placement="auto" title="View all recurring tasks from all lists on a single, sorted page">
                $icons->{'repeat'} Show Recurring Tasks
                </a>
            </p>
            </div>
        </div>
        </div>
    </div>

    <script>
    // Save and restore tab selection using URL hash
    document.addEventListener('DOMContentLoaded', function() {
        var listsTabs = document.getElementById('listsTabs');
        var hash = window.location.hash;

        // If there's a hash that matches a tab, activate it
        if (hash) {
        var targetTab = document.querySelector('[data-bs-target="' + hash + '"]');
        if (targetTab) {
            var tab = new bootstrap.Tab(targetTab);
            tab.show();
        }
        }

        // Save the active tab to URL hash when tabs are clicked
        var tabButtons = listsTabs.querySelectorAll('.nav-link');
        tabButtons.forEach(function(button) {
        button.addEventListener('shown.bs.tab', function(event) {
            var target = event.target.getAttribute('data-bs-target');
            window.location.hash = target;
        });
        });

        // Initialize tooltips on buttons with title attributes
        var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
        tooltipTriggerList.map(function (tooltipTriggerEl) {
        return new bootstrap.Tooltip(tooltipTriggerEl, {
            delay: { $global->{'tooltip_delay'} }
        });
        });
    });
    </script>
    ~;

    # Build the list of available lists for moving tasks as JSON
    my $move_lists_sth = $dbh->prepare('SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL AND id > 1 ORDER BY Title ASC');
    $move_lists_sth->execute();
    my @move_lists;
    while (my $ml = $move_lists_sth->fetchrow_hashref()) {
        push @move_lists, { id => $ml->{'id'}, title => html_escape($ml->{'Title'}) };
        } # End move lists building

    # Convert to JSON for JavaScript use
    my $move_lists_json = '[';
    foreach my $i (0 .. $#move_lists) {
        my $ml = $move_lists[$i];
        $move_lists_json .= qq~{"id":"$ml->{'id'}","title":"$ml->{'title'}"}~;
        $move_lists_json .= ',' if $i < $#move_lists;
        }
    $move_lists_json .= ']';

    $html .= footer();
    return $html;
    } # End show_lists()


sub show_settings { # show_settings() - Show a form with all the configurable settings and allow them to be updated
    my $html .= header();

    $html .= start_card("Settings", $icons->{'gear'}, 0);
    $html .= qq~
        <form method="post" action="/settings_form" style="display:inline;">
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
                $html .= config_show_option('cfg_show_dates','Show Dates','Include the Date when a Task was added or completed in the Task List','check',0,0);
                $html .= config_show_option('cfg_show_lists','Show Lists','Include the List name a task belongs to in the Task List','check',0,0);

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

            $html .= config_show_option('cfg_show_quickswitcher','Show Quick Switcher','Show the quick switcher at the top of every page','check',0,0);
            $html .= config_show_option('cfg_export_all_cols','Export date and list',"When using the export buttons, $global->{'app_title'} will normally just export the Task name. Enable this to include the date and list for each task",'check',0,0);
            $html .= config_show_option('cfg_backup_number_to_keep','Number of daily backups to keep',"Each day, $global->{'app_title'} makes a backup of its database. This setting controls how many days worth of backups to keep. Older backups will be deleted automatically. Range 1-100",'number',1,100);
            $html .= config_show_option('cfg_version_check','Check for new versions','If checked, Taskpony will occasionally check for new versions of itself and show a small badge in the footer if one is available','check',0,0);
            $html .= config_show_option('cfg_header_colour','Default Highlight Colour','Select default colour for panel header backgrounds and highlights','colour',0,0);
            $html .= config_show_option('cfg_background_image','Enable background image','If checked, an JPG can be uploaded through this form below and will be used as a background','check',0,0);

        $html .= qq~

        <br/>
        <div class="text-end">
            <button class="btn btn-primary">Save Settings</button>
        </div>

        </div>

        ~;

        # End the main form
        $html .= qq~
                    </div>
                </div>
            </div>
        </form>
        ~;

        $html .= end_card(0);

        $html .= start_card('Background Image Upload', $icons->{'image'}, 0);

        # Start a second form for the background image upload
        $html .= qq~
        <form method="post" action="/settings_background_form" enctype="multipart/form-data">
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

    $html .= end_card(0);
    $html .= footer();
    return $html;
    } # End show_settings()

sub show_maintasks { # show_maintasks() - Show the main list of tasks, either active or completed, for a given list or all lists
    my $html = header();

    # Set default titlebar to be the quick add form for the selected list
    my $titlebar = qq~</h2>
                        <form method="post" action="/task_form_add" class="d-flex align-items-center gap-2 m-0">
                            <input name="Title" id="tasktitle" autofocus class="form-control" required maxlength="200" placeholder="Add a new task to '$page->{'list_name'}' " />
                            <button class="btn btn-primary" type="submit">Add</button>
                        </form>
                        <h2>
                    ~;

    # If showing all lists, change titlebar to show what is being displayed instead of the form
    if ($page->{'list_id'} == 1) {
        if ($page->{'show_completed'} == 1) {
            $titlebar = "Showing completed tasks from all lists";
            } else {
            $titlebar = "Showing active tasks from all lists";
            }
        }

    $html .= start_card($titlebar,'',1);

    ####################################
    # Show main list of tasks

    # Show completed tasks if ?sc=1
    if ($page->{'show_completed'} == 1) {
        $html .= show_tasks(2,$page->{'list_id'},0);
        } else { # Else show active tasks
        $html .= show_tasks(1,$page->{'list_id'},0);
        }

    # End list of tasks, continue with box
    #####################################

    $html .= end_card(1);
    $html .= footer();
    return $html;
    } # End show_tasks()

 sub show_list_edit { # show_list_edit() - Show the form to edit a list, pre-populated with the list details
    my ($edit_listid, $from_page) = @_;  # $from_page: 1 = return to /lists, 2 = return to /list/X, 3 = return to where you were before
    my $list;
    my $gutter_text = 'This will be a new list which will be created when you click "Save List"';
    my $card_title = "Create New List";
    if ($edit_listid) { # Editing an existing list, so load details
        my $sth = $dbh->prepare('SELECT * FROM ListsTb WHERE id = ?');
        $sth->execute($edit_listid);
        $list = $sth->fetchrow_hashref();
        $gutter_text = "This is list id #$edit_listid which was created on $list->{'CreatedDate'}";
        $card_title = "Edit List: $list->{'Title'}";
        } else { # No listid supplied, assume it's new. Prime some values
        $list->{'Title'} = '';
        $list->{'Description'} = '';
        $list->{'id'} = 0;
        }

    my $html = header();
    $html .= start_card($card_title, $icons->{'list'}, 0);
    $html .= qq~
            <form method="post" action="/list_form/$edit_listid" class="row g-3">
                <input type="hidden" name="return_page" id="return_page" value="$from_page" />

                <div class="col-12">
                    <label class="form-label" data-bs-toggle="tooltip" data-bs-placement="auto" title="The name of this List">Title</label>
                    <input name="Title" class="form-control" required maxlength="255" value="~ . html_escape($list->{'Title'}) . qq~" />

                    <br>
                    <label class="form-label" data-bs-toggle="tooltip" data-bs-placement="auto" title="A brief description of this List">Description</label>
                    <textarea name="Description" class="form-control" rows="4" maxlength="2000">~ . html_escape($list->{'Description'} // '') . qq~</textarea>

                    <br>

                    <div class="row align-items-center">
                        <div class="col-md-6">
                            <label class="form-label" data-bs-toggle="tooltip" data-bs-placement="auto" title="Select a colour for this List which will be displayed in the quickswitcher at the top of the page, if enabled. It also adds a flash top-right.">Quickswitch Colour</label>
                            <input type="color" name="Colour" class="form-control form-control-color" value="~ . html_escape($list->{'Colour'} // '') . qq~" />
                        </div>

                        <div class="col-md-6 d-flex align-items-center">
                            <div class="form-check">
                                <input class="form-check-input" type="checkbox" name="clear_colours" id="clear_colours">
                                <label class="form-check-label" for="clear_colours" data-bs-toggle="tooltip" data-bs-placement="auto" title="Check this to remove special highlight colouring for this List">
                                    Remove from Quickswitcher
                                </label>
                            </div>
                        </div>
                    </div>

                    <div class="text-end">
                        <button class="btn btn-primary" type="submit">Save List</button>
                        <a class="btn btn-secondary" href="/lists">Cancel</a>
                        <a class="btn btn-danger" href="/list_archive/$list->{'id'}" data-bs-toggle="tooltip" data-bs-placement="auto" title="Archive this List" onclick="return confirm('Are you sure you want to archive this list?');">Archive List</a>
                    </div>
                <hr>
                <p class="text-$config->{'cfg_header_colour'}">$gutter_text</p>
                </div>
            </form>
        </div>
    ~;
    $html .= end_card(0);
    $html .= footer();
    return $html;
    } # End show_list_edit()

sub show_404 {
    my $badpath = shift;
    print STDERR "404 Not Found: $badpath\n";
    my $res = Plack::Response->new(404);
    $res->status(404);
    $res->header('Content-Type' => 'text/html; charset=utf-8');
    $res->body(qq~
        <!doctype html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>404 Not Found - $global->{'app_title'}</title>
            <link rel="stylesheet" href="/static/css/bootstrap.min.css">
            <style>
                body { background-color: #1A2122; color: white; }
                .error-container { min-height: 100vh; display: flex; align-items: center; justify-content: center; }
                .error-card { text-align: center; padding: 40px; background: rgba(15, 23, 36, 0.8); border-radius: 12px; max-width: 500px; box-shadow: 0 4px 12px rgba(0,0,0,0.4); }
                .error-code { font-size: 96px; font-weight: bold; color: #dc3545; margin: 0; line-height: 1; }
                .error-message { font-size: 24px; margin: 20px 0; }
                .error-description { color: rgba(255,255,255,0.7); margin-bottom: 30px; }
                .btn { min-width: 200px; }
            </style>
        </head>
        <body>
            <div class="error-container">
                <div class="error-card">
                    <div class="error-code">404</div>
                    <h1 class="error-message">Page Not Found</h1>
                    <p class="error-description">$global->{'app_title'} has escaped the paddock!</p>
                    <p class="error-description small">Path does not exist: <span class="text-white">$badpath</span></p>
                    <a href="/" class="btn btn-lg btn-success">Go back to safety</a>
                </div>
            </div>
        </body>
        </html>
        ~);
    return $res->finalize;
    }

sub show_quickswitcher { # show_quickswitcher() - Show the quickswitcher which is a row of coloured dots
    return if ($config->{'cfg_show_quickswitcher'} ne 'on');  # Not configured. Bailing.
    my $html = '';
    # Loop through lists and show a dot for each, using the list colour if set
    my $sth = $dbh->prepare('SELECT id, Title, Colour FROM ListsTb WHERE DeletedDate IS NULL AND Colour IS NOT NULL ORDER BY Title ASC');
    $sth->execute();
    while (my $list = $sth->fetchrow_hashref()) {
        $html .= qq~
            <!-- Quickswitcher dot for list $list->{'Title'} -->
            <a href="/list/$list->{'id'}" class="quickswitcher-dot" style="background-color: $list->{'Colour'};" data-bs-toggle="tooltip" data-bs-placement="auto" title="html_escape($list->{'Title'})"></a>
            ~;
        }
    return $html;
    } # End show_quickswitcher()

# End SHOW functions
###############################################

###############################################
# MISC functions - things that don't fit anywhere else

sub return_default_listid { # return_default_listid() - returns the default list id from ConfigTb
    return single_db_value("SELECT `id` FROM ListsTb WHERE isDefault = 1 AND DeletedDate IS NULL LIMIT 1");
    }

sub set_default_listid { # set_default_listid($list_id) - sets the default list id in ConfigTb
    my ($list_id) = @_;
    debug("Setting default list id to $list_id in ConfigTb");
    $dbh->do("INSERT INTO ConfigTb (`key`,`value`) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?;",
        undef,
        'active_list',
        $list_id,
        $list_id
        ) or print STDERR "Failed to save active_list to ConfigTb: " . $dbh->errstr;
    }

sub update_db_mtime {  # Update the global $page->{'db_mtime'} variable with the current database file modification time
    $page->{'db_mtime'} = (stat($global->{'db_path'}))[9] // 0;
    }

sub verify_valid_list { # verify_valid_list() - checks whether a list id is valid and active, sets global $page->{'list_id'} to a good value
    # Check currently active list is valid
    my $force_reload = shift // 0;
    debug("Verifying active list id ($page->{'list_id'}) is valid and active...\n");
    my $changed_list_id = $force_reload ? 1 : 0;

    # Step 1: Check if current list_id is viable
    my $exists = single_db_value("SELECT COUNT(*) FROM ListsTb WHERE id = ? AND DeletedDate IS NULL", $page->{'list_id'});
    if (!$exists or ($exists == 0) ) { # Not viable, let's try to get from config
        debug("INFO: Current active list ($page->{'list_id'}) is not valid or is deleted. Trying to find a better value from ConfigTb.\n");

        my $cfg_active_list = single_db_value("SELECT `value` FROM ConfigTb WHERE `key` = 'active_list' LIMIT 1");
        if ($cfg_active_list && $cfg_active_list =~ /^\d+$/) {
            debug("INFO: Found active_list from ConfigTb: $cfg_active_list. Checking if it's viable.\n");
            # Recheck if this ConfigTb value is viable in the database
            $exists = single_db_value("SELECT COUNT(*) FROM ListsTb WHERE id = ? AND DeletedDate IS NULL", $cfg_active_list);
            if ($exists && $exists > 0) { # ConfigTb value is valid and viable
                debug("INFO: Active list id from ConfigTb ($cfg_active_list) is valid. Setting active list to this.\n");
                $page->{'list_id'} = $cfg_active_list;
                $changed_list_id = 1;
                } else { # ConfigTb value is not viable, need to find first viable list
                    debug("INFO: Active list id from ConfigTb ($cfg_active_list) is not valid or is deleted. Attempting to load first viable list.\n");
                    my $new_list_id = single_db_value("SELECT `id` FROM ListsTb WHERE DeletedDate IS NULL ORDER BY id ASC LIMIT 1");
                    if ($new_list_id && $new_list_id =~ /^\d+$/) {
                        print STDERR "INFO: First viable list id is $new_list_id. Setting active list to this.\n";
                        $page->{'list_id'} = $new_list_id;
                        $changed_list_id = 1;
                    } else {
                        print STDERR "ERROR: No viable lists found in database. This should not be possible as there should always be at least one valid list. Setting active list to 1 (All lists) and showing error message on page.\n";
                        $page->{'list_id'} = 1;  # Set to 1 to show error message on page
                        $changed_list_id = 1;
                        add_alert("Error: No viable lists found in database. Please create a list to get started.");
                    }
                }
            } else { # No valid list_id in ConfigTb either, find first viable list
            debug("INFO: No valid active_list in ConfigTb. Attempting to load first viable list.");
            my $new_list_id = single_db_value("SELECT `id` FROM ListsTb WHERE DeletedDate IS NULL ORDER BY id ASC LIMIT 1");
            if ($new_list_id && $new_list_id =~ /^\d+$/) {
                debug("INFO: First viable list id is $new_list_id. Setting active list to this.");
                $page->{'list_id'} = $new_list_id;
                $changed_list_id = 1;
                } else {
                print STDERR "ERROR: No viable lists found in database. This should not be possible as there should always be at least one valid list. Setting active list to 1 (All lists) and showing error message on page.\n";
                $page->{'list_id'} = 1;  # Set to 1 to show error message on page
                $changed_list_id = 1;
                add_alert("Error: No viable lists found in database. Please create a list to get started.");
                }
            }
        }

    # Always ensure the related list values are populated (even if list_id didn't change)
    # Only call set_default_listid if the list_id actually changed
    if ($changed_list_id == 1) { # List ID changed, reload related values and save to config
        debug("INFO: List ID changed to $page->{'list_id'}. Restoring values from database.");
        $page->{'list_name'} = single_db_value("SELECT `Title` FROM ListsTb WHERE `id` = ?", $page->{'list_id'}) || 'Unknown List';
        $page->{'list_colour'} = single_db_value("SELECT `Colour` FROM ListsTb WHERE `id` = ?", $page->{'list_id'}) || '0';
        # Save the new active list id to config for next time
        set_default_listid($page->{'list_id'});
        } else { # List ID didn't change, but ensure related values are populated if missing
        if ( (!$page->{'list_name'} ) || (!$page->{'list_colour'} ) ) {
            debug("INFO: Related list values are missing but list ID didn't change. Populating from database without saving.");
            $page->{'list_name'} = single_db_value("SELECT `Title` FROM ListsTb WHERE `id` = ?", $page->{'list_id'}) || 'Unknown List';
            $page->{'list_colour'} = single_db_value("SELECT `Colour` FROM ListsTb WHERE `id` = ?", $page->{'list_id'}) || '0';
            }
        }

    } # End verify_valid_list()

sub check_latest_release {      # check_latest_release()   Get latest release from github
    if ($config->{'cfg_version_check'} ne 'on') { return; }             # If disabled, return early
    if ($global->{'new_version_available'} == 1) { return; }            # No point checking again if we know there is a new version waiting

    my $github_latest_version;

    my $http = HTTP::Tiny->new(
        agent => "taskpony-version-check/$global->{'app_version'}",
        timeout => 10
        );

    my $res = $http->get($global->{'github_version_url'});
    if ($res->{success}) {
        my $data = decode_json($res->{content});
        $github_latest_version = $data->{tag_name};
        $github_latest_version =~ s/\D//g;   # Just return the digits for numeric comparison
        } else {
        print STDERR "Latest version check from github failed. Non-fatal, continuing\n";
        return;
        }

    my $normalised_app_version = $global->{'app_version'};
    $normalised_app_version =~ s/\D//g;

    if ($github_latest_version > $normalised_app_version) {
        print STDERR "New version of $global->{'app_title'} is available\n";
        $global->{'new_version_available'} = 1;
        }
    return;
    }  # End check_latest_release()

sub ensure_sensible_config_range { # ensure_sensible_config_range($value, $min, $max)  Ensure a numeric value is within a sensible range, otherwise return the nearest bound
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

sub save_config {  # save_config() Save contents of $config hashref to ConfigTb
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

sub backup_database {  # Backup the database by rotating old backups and creating a new one. Will only be called once a day from run_daily_tasks() logic
    print STDERR "Backing up database...  Keeping " . $config->{cfg_backup_number_to_keep} . " backups\n";

    # Start counting back from the currently defined max backups to keep. Delete the oldest, then rename each one down by 1, then create the new backup as .0
    for (my $i = $config->{cfg_backup_number_to_keep} - 1; $i >= 0; $i--) {
        my $old_backup = "$global->{'db_path'}.$i";
        my $new_backup = "$global->{'db_path'}." . ($i + 1);
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
    my $new_backup_0 = "$global->{'db_path'}.0";
    print STDERR "Creating new backup by copying $global->{'db_path'} to $new_backup_0\n";
    copy($global->{'db_path'}, $new_backup_0) or print STDERR "WARN: Failed to create new backup $new_backup_0: $!\n";
    } # End backup_database()

sub run_daily_tasks {  # Run any daily tasks we need to. Return if already run today.
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

    # Run daily tasks here, such as backing up the database, sending email summaries, etc.
    backup_database();  # Backup the database by one iteration

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
                    AddedDate = datetime('now')
                WHERE id = ?
                ", undef, $task->{'id'}
                ) or print STDERR "WARN: Failed to reactivate recurring task ID $task->{id}: " . $dbh->errstr;
            }
        }

    # We ran run_daily_tasks() today, so let's update the last run time and return
    $dbh->do("UPDATE ConfigTb SET value = date('now') WHERE key = 'cfg_last_daily_run'") or print STDERR "WARN: Failed to update last daily run date: " . $dbh->errstr;

    # Frivolity: Check if a special date and change the logo
    # If month is December and day is between 20 and 31, show a festive icon
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    if ( ($mon == 11) && ($mday >= 20) && ($mday <= 31) ) {
        $global->{'taskpony_icon'} = 'taskpony-logo-xmas.png';
        print STDERR "Taskponies love Christmas!\n";
        } else {
        $global->{'taskpony_icon'} = 'taskpony-logo.png';  # Reset to normal logo
        }
    # Back to seriousness

    return;
    } # End run_daily_tasks()

sub calculate_stats { # calculate_stats() Calculate stats and populate the global $stats hashref
    # Check to see whether we've run this recently. If so, return before hitting the database
    if ( $stats->{stats_last_calculated} && time - $stats->{stats_last_calculated} < $stats->{'calculate_stats_interval'} ) { return; }

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

sub config_load { # config_load() - Load all key/value pairs from ConfigTb into $config hashref
    print STDERR "Loading configuration from $global->{'db_path'} in ConfigTb\n";

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

sub human_friendly_date { # human_friendly_date($db_date) - Convert a database datetime string into a human friendly relative time string
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
    $diff_months = 1 if $diff_months < 1;
    return "$diff_months month" . ($diff_months == 1 ? '' : 's') . " ago" if $diff_months < 12;

    my $diff_years = int($diff_days / 365);
    return "$diff_years year" . ($diff_years == 1 ? '' : 's') . " ago";
    } # End human_friendly_date()

# End MISC functions
###############################################

###############################################
# ACTION functions - things that change stuff
###############################################

sub action_task_complete { # Set task nn as completed  (Status 2) in TasksTb
    my ($task_id) = @_;
    if ($task_id && $task_id =~ /^\d+$/) {  # Check it's a valid numeric ID before we do anything
        print STDERR "ACTION: Marking task $task_id as complete\n";
        my $sth = $dbh->prepare(
            'UPDATE TasksTb SET Status = 2, CompletedDate = CURRENT_TIMESTAMP WHERE id = ?'
            );
        eval { $sth->execute($task_id); 1 } or print STDERR "Setting task $task_id as completed failed: $@";
        $stats->{'tasks_completed_today'} += 1;
        add_alert("Task #$task_id marked as completed. $stats->{'tasks_completed_today'} tasks completed today!");
        } else {
        print STDERR "WARN: Invalid task ID ($task_id) passed to action_task_complete\n";
        }
    } # End action_task_complete

sub action_task_delete { # Delete task nn from TasksTb
    my ($task_id) = @_;
    if ($task_id && $task_id =~ /^\d+$/) {
        print STDERR "ACTION: Deleting task $task_id\n";
        my $sth = $dbh->prepare('DELETE FROM TasksTb WHERE id = ?');
        eval { $sth->execute($task_id); 1 } or print STDERR "WARN: Delete TasksTb.id=$task_id failed: $@";
        add_alert("Task #$task_id deleted.");
        } else {
        print STDERR "WARN: Invalid task ID ($task_id) passed to action_task_delete\n";
        }
    } # End action_task_delete

sub action_task_activate { # Set task nn as active (Status 1) in TasksTb
    my ($task_id) = @_;
    if ($task_id && $task_id =~ /^\d+$/) {
        print STDERR "ACTION: Re-activating task $task_id\n";
        my $sth = $dbh->prepare('UPDATE TasksTb SET Status = 1, AddedDate = CURRENT_TIMESTAMP, CompletedDate = NULL WHERE id = ?');
        eval { $sth->execute($task_id); 1 } or print STDERR "WARN: Update TasksTb.id=$task_id failed: $@";
        add_alert("Task #$task_id re-activated.");
        } else {
        print STDERR "WARN: Invalid task ID ($task_id) passed to action_task_activate\n";
        }
    } # End action_task_activate

sub action_task_edit { # Show the edit form for task nn. Function returns full html
    my ($task_id, $res) = @_;
    if ($task_id && $task_id =~ /^\d+$/) {
        if ($task_id > 0) {
        my $sth = $dbh->prepare('SELECT * FROM TasksTb WHERE id = ?');
        $sth->execute($task_id);
        my $task = $sth->fetchrow_hashref() or print STDERR "WARN: No task found with ID ($task_id) passed to action_task_edit\n";

        if ($task) {
            my $html = header();

            # Build list dropdown for later use in the form
            my $list_dropdown = qq~<select name="ListId" class="form-select" required>~;
            my $list_sth = $dbh->prepare('SELECT id, Title FROM ListsTb WHERE DeletedDate IS NULL AND id > 1 ORDER BY Title ASC');
            $list_sth->execute();
            eval { $list_sth->execute(); 1 } or print STDERR "WARN: Update TasksTb.id=$task_id failed: $@";

            # Build list
            while (my $list= $list_sth->fetchrow_hashref()) {
                my $selected = ($list->{'id'} == $task->{'ListId'}) ? ' selected' : '';
                my $title = html_escape($list->{'Title'});
                $list_dropdown .= qq~<option value="$list->{'id'}"$selected>$title</option>~;
                }
            $list_dropdown .= '</select>';

            my $task_status = 'Completed';
            if ($task->{'Status'} == 1) { $task_status = 'Active'; }

            $html .= start_card("Edit Task #$task_id - $task_status", $icons->{'edit'}, 0);

            $html .= qq~
                        <form method="post" action="/task_form_edit/$task_id" class="row g-3">

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
                                            $smallicons->{'info'}
                                        </span>
                                        </div>
                                    </div>

                                    <div class="border p-3 flex-fill ">

                                        <div class="d-flex align-items-center gap-2">
                                            Repeat every
                                                <input type="number" class="form-control form-control-sm" style="width: 80px;"
                                                    name="RecurringIntervalDay" min="1" max="365" value="$task->{'RecurringIntervalDay'}">
                                                <span>
                                                    days
                                                </span>
                                                <span data-bs-toggle="tooltip" data-bs-placement="auto" title="How many days after completion should this task re-activate? Range 1-365">
                                                    $smallicons->{'info'}
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
                                <a class="btn btn-warning" href="/task_complete/$task_id">Set Task as Completed</a>
                                ~;
                                } else {
                                $html .= qq~
                                <a class="btn btn-warning" href="/task_activate/$task_id">Set Task as Active</a>
                                ~;
                                }

                            $html .= qq~
                                <a class="btn btn-danger" href="/task_delete/$task_id">Delete Task</a>
                            </div>

                            <br>
                            <p class="text-secondary">
                                This task was created $task->{'AddedDate'}
                                ~;
                                if ($task->{'CompletedDate'}) {
                                    $html .= qq~and completed $task->{'CompletedDate'}~;
                                    }
                                $html .= qq~
                            </p>

                            </div>

                        </form>
                ~;

                $html .= end_card(0);
                $html .= footer();
                return $html;
                } else {
                print STDERR "WARN: No task found with ID ($task_id) passed to action_task_edit\n";
                return "Error in task_edit(): No task found with that ID";
                }
            } else {
            print STDERR "WARN: Invalid task ID ($task_id) passed to action_task_edit\n";
            return "Error in task_edit(): Invalid task ID";
            }
        } # End action_task_edit

    }

sub action_list_unarchive { # Undelete list nn from ListsTb by setting DeletedDate to NULL
    my ($list_id) = @_;
    if ($list_id && $list_id =~ /^\d+$/) {
        if ($list_id > 1) { # Don't allow undeleting "All Tasks Lists"
            print STDERR "ACTION: Undeleting list $list_id\n";
            my $sth = $dbh->prepare('UPDATE ListsTb SET DeletedDate = NULL WHERE id = ? LIMIT 1');
            eval { $sth->execute($list_id); 1 } or print STDERR "WARN: List undelete failed: $@";
            add_alert("List #$list_id restored.");
            } else {
            print STDERR "WARN: Attempt to undelete list with invalid ID ($list_id) passed to action_list_unarchive\n";
            }
        } else {
        print STDERR "WARN: Invalid list ID ($list_id) passed to action_list_unarchive\n";
        }
    } # End action_list_unarchive

sub action_list_hard_delete {  # Permanently delete List nn
    my ($list_id) = @_;
    if ($list_id && $list_id =~ /^\d+$/) {
        if ($list_id > 1) { # Don't allow deleting "All Tasks Lists"
            print STDERR "ACTION: Deleting list $list_id\n";
            my $sth = $dbh->prepare('DELETE FROM ListsTb WHERE id = ? LIMIT 1');
            eval { $sth->execute($list_id); 1 } or print STDERR "WARN: List delete failed: $@";
            add_alert("List #$list_id deleted.");
            } else {
            print STDERR "WARN: Attempt to delete list with invalid ID ($list_id) passed to action_list_hard_delete\n";
            }
        } else {
        print STDERR "WARN: Invalid list ID ($list_id) passed to action_list_hard_delete\n";
        }
    } # End action_list_hard_delete

sub action_list_set_default { # Set List nn as default by setting cfg_default_list in ConfigTb
    my ($list_id) = @_;
    if ($list_id && $list_id =~ /^\d+$/) {
        print STDERR "ACTION: Setting list $list_id as default\n";
        single_db_value('UPDATE ListsTb SET IsDefault = 0 WHERE IsDefault = 1'); # Clear current default
        my $sth = $dbh->prepare('UPDATE ListsTb SET IsDefault = 1 WHERE id = ?');
        eval { $sth->execute($list_id); 1 } or print STDERR "WARN: Setting default list failed: $@";
        add_alert("List #$list_id set as default.");
        } else {
        print STDERR "WARN: Invalid list ID ($list_id) passed to action_list_set_default\n";
        }
    } # End action_list_set_default

sub action_list_set_alltasks_active { # Set all tasks in "All Tasks" list (ListId 1) as active by setting Status to 1 and clearing CompletedDate
    my ($list_id) = @_;
    if ($list_id && $list_id =~ /^\d+$/) {
        print STDERR "ACTION: Setting all tasks in list $list_id as active\n";
        my $sth = $dbh->prepare('UPDATE TasksTb SET Status = 1, AddedDate = CURRENT_TIMESTAMP, CompletedDate = NULL WHERE ListId = ? AND Status = 2');
        eval { $sth->execute($list_id); 1 } or print STDERR "WARN: Set all tasks active failed: $@";
        add_alert("All tasks in list $list_id set as active.");
        } else {
        print STDERR "WARN: Invalid list ID ($list_id) passed to action_list_set_alltasks_active\n";
        }
    } # End action_list_set_alltasks_active

sub action_list_set_alltasks_completed { # Set all tasks in "All Tasks" list (ListId 1) as completed by setting Status to 2 and CompletedDate to current timestamp
    my ($list_id) = @_;
    if ($list_id && $list_id =~ /^\d+$/) {
        print STDERR "ACTION: Setting all tasks in list $list_id as completed\n";
        my $sth = $dbh->prepare('UPDATE TasksTb SET Status = 2, CompletedDate = CURRENT_TIMESTAMP WHERE ListId = ? AND Status = 1');
        eval { $sth->execute($list_id); 1 } or print STDERR "WARN: Set all tasks completed failed: $@";
        add_alert("All tasks in list $list_id set as completed.");
        } else {
        print STDERR "WARN: Invalid list ID ($list_id) passed to action_list_set_alltasks_completed\n";
        }
    } # End action_list_set_alltasks_completed

sub action_list_harddelete_alltasks { # Permanently delete all tasks in List NN
    my ($list_id) = @_;
    if ($list_id && $list_id =~ /^\d+$/) {
        if ($list_id > 1) { # Don't allow deleting all tasks in "All Tasks Lists"
            print STDERR "ACTION: Permanently deleting all tasks in list $list_id\n";
            my $count = single_db_value('SELECT COUNT(*) FROM TasksTb WHERE ListId = ?', $list_id) // 0;
            my $sth = $dbh->prepare('DELETE FROM TasksTb WHERE ListId = ?');
            eval { $sth->execute($list_id); 1 } or print STDERR "WARN: Delete all tasks failed: $@";
            add_alert("All $count tasks in list #$list_id permanently deleted.");
            } else {
            print STDERR "WARN: Attempt to delete all tasks in list with invalid ID ($list_id) passed to action_list_harddelete_alltasks\n";
            }
        } else {
        print STDERR "WARN: Invalid list ID ($list_id) passed to action_list_harddelete_alltasks\n";
        }
    } # End action_list_harddelete_alltasks

sub action_list_archive { # Make List nn archived by setting DeletedDate to current timestamp
    my ($list_id) = @_;
    if ($list_id && $list_id =~ /^\d+$/) {
        if ($list_id > 1) { # Don't allow deleting "All Tasks Lists"
            print STDERR "ACTION: Archiving list $list_id\n";
            my $sth = $dbh->prepare('UPDATE ListsTb SET DeletedDate = CURRENT_TIMESTAMP WHERE id = ? LIMIT 1');
            eval { $sth->execute($list_id); 1 } or print STDERR "WARN: List archive failed: $@";
            add_alert("List #$list_id archived.");
            } else {
            print STDERR "WARN: Attempt to archive list with invalid ID ($list_id) passed to action_list_archive\n";
            }
        } else {
        print STDERR "WARN: Invalid list ID ($list_id) passed to action_list_archive\n";
        }
    } # End action_list_archive

sub action_task_add { # Show the add task form
    my $html = header();
    $html .= qq~
        <div class="container py-2">
            <h3 class="mb-3">Add Task</h3>
            <form method="post" action="/task_form_add" class="row g-3">
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
    return $html;
    } # End action_task_add

# End Action functions
###############################################

###############################################
# RECEIVE functions - to receive forms
###############################################

sub receive_form_task_edit { # Receive Edit Task form
    my ($task_id, $req) = @_;
    if ($task_id && $task_id =~ /^\d+$/) {
        my $sth = $dbh->prepare('SELECT * FROM TasksTb WHERE id = ?');
        $sth->execute($task_id);
        my $task = $sth->fetchrow_hashref() or print STDERR "WARN: No task found with ID ($task_id) passed to receive_form_task_edit\n";

        if ($task) {
            my $title = sanitize($req->param('Title') // '');
            my $desc  = sanitize($req->param('Description') // '');
            my $list_id = $req->param('ListId') // 0;
            my $is_recurring = sanitize($req->param('IsRecurring') // '');
            my $recurring_interval = sanitize($req->param('RecurringIntervalDay') // '');

            debug("receive_form_task_edit: Received form data for task $task_id - Title: $title, ListId: $list_id, IsRecurring: $is_recurring, RecurringIntervalDay: $recurring_interval");

            # Validate list_id is numeric
            if ($list_id !~ /^\d+$/) {
                print STDERR "WARN: Task $task_id list_id is not numeric. Keeping original list.\n";
                $list_id = $task->{'ListId'};
                }

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
            if (length $title && $list_id > 1) {
                my $sth = $dbh->prepare(
                    'UPDATE TasksTb SET Title = ?, Description = ?, ListId = ?, IsRecurring = ?, RecurringIntervalDay = ? WHERE id = ?'
                    );
                eval { $sth->execute($title, $desc, $list_id, $is_recurring, $recurring_interval, $task_id); 1 } or print STDERR "Task update for $task_id failed: $@";
                debug("Task $task_id updated");
                add_alert("Task #$task_id updated");
                } else {
                print STDERR "WARN: Invalid data submitted in edit form for task ID ($task_id)\n";
                add_alert("Error updating task #$task_id: Invalid input data.");
                }
            }
        return;
        } else {
        print STDERR "WARN: No task found with ID ($task_id) passed to receive_form_task_edit\n";
        add_alert("Error updating task #$task_id: Task not found.");
        }
    } # End receive_form_task_edit

sub receive_form_task_add { # Receive Add Task form. No direct output
    my ($req) = @_;

    my $title = sanitize($req->param('Title') // '');
    my $desc  = sanitize($req->param('Description') // '');

    if (length $title) {
        my $sth = $dbh->prepare( 'INSERT INTO TasksTb (Title, Description, ListId) VALUES (?, ?, ?)' );
        eval { $sth->execute($title, $desc, $page->{'list_id'}); 1 } or print STDERR "WARN: Task insert into list $page->{'list_id'} failed: $@";
        }

    $stats->{'tasks_added_today'} += 1;
    add_alert("Task '$title' added.  That's $stats->{'tasks_added_today'} new tasks today!");
    } # End /receive_form_task_add

sub receive_settings { # Receive Settings form. No direct output
    my ($req) = @_;

    # Loop through config keys and try to get them from param
    for my $key (keys %$config) {
        my $new_val;
        $new_val = $req->param($key);

        if ($new_val) {
            debug("Config value returned: ($key) = ($new_val) [$config->{$key}]");
            } else { # No parameter passed for key, store existing
            debug("No parameter passed for ($key), using existing [$config->{$key}]");
            # Special handling for checkboxes which will return void if not set
            if ($key =~ 'cfg_include_datatable_|cfg_export_all_cols|cfg_show_dates|cfg_show_quickswitcher|cfg_version_check|cfg_include_datatable_search|cfg_background_image|cfg_show_lists') {
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
    add_alert("Configuration saved");
    }

sub receive_settings_background { # Receive Settings form for background image upload. No direct output
    my ($req) = @_;
    my $upload = $req->upload('background') or return [400, [], ['No file uploaded']];

    if ($upload->size > 5 * 1024 * 1024) {
        print STDERR "Uploaded background is too large\n";
        add_alert("Uploaded image was too large. Size limited to 5MB");
        return [302, [ Location => '/settings' ], []];
        }

    my $type = $upload->content_type;
    my $ext =
        $type eq 'image/jpeg' ? 'jpg' :
        return [400, [], ['Unsupported type']];

    my $src = $upload->path or return [500, [], ['Upload has no temp path']];

    my $tmp = "$global->{'bg_path'}.tmp";  # Write out a temporary file as bg pic may be slow to upload

    copy($src, $tmp) or return [500, [], ["Copy failed: $!"]];

    rename $tmp, $global->{'bg_path'} or return [500, [], ["Rename failed: $!"]];

    add_alert("Background image updated");
    return [302, [ Location => '/settings' ], []];
    } # End receive_settings_background()

sub receive_form_list { # Receive New/edited list form
    my ($req,$edit_id) = @_;
    debug("receive_form_list: Received form submission for list ID ($edit_id)");

    if ($edit_id && $edit_id =~ /^\d+$/ && $edit_id > 0) { # We've received an edited form with an id
        my $title = sanitize($req->param('Title') // '');
        my $desc = sanitize($req->param('Description') // '');
        my $colour = sanitize($req->param('Colour') // '');
        my $clear_colours = $req->param('clear_colours') // '';
        if ($clear_colours eq 'on') {  # Remove override
            $colour = '';
            }

        if (length $title && $page->{'list_id'} > 1) {
            my $sth = $dbh->prepare( 'UPDATE ListsTb SET Title = ?, Description = ?, Colour = ?   WHERE id = ?' );
            eval { $sth->execute($title, $desc, $colour, $edit_id); 1 } or print STDERR "Update failed: $@";
            $page->{'list_colour'} = $colour;
            add_alert("List '$title' updated");
            } else {
            print STDERR "WARN: Invalid data submitted in edit form for list ID ($edit_id)\n";
            add_alert("Error updating list #$edit_id: Invalid input data.");
            }
        } else { # No ID, this is a new list
        my $title = sanitize($req->param('Title') // '');
        my $desc = sanitize($req->param('Description') // '');
        my $colour = sanitize($req->param('Colour') // '');
        if (length $title) {
            my $sth = $dbh->prepare( 'INSERT INTO ListsTb (Title, Description, Colour) VALUES (?, ?, ?)' );
            eval { $sth->execute($title, $desc, $colour); 1 } or print STDERR "Insert failed: $@";
            add_alert("List '$title' added");
            } else {
            print STDERR "WARN: Invalid data submitted in add form for new list\n";
            add_alert("Error adding new list: Invalid input data.");
            }
        }
    } # end receive_form_list()

# End Receive functions
###############################################

# End all Functions
##############################################

# End of Taskpony
#################################################
