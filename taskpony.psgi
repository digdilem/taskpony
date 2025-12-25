#!/usr/bin/env/perl
# Taskpony - a simple perl PSGI web app for various daily tasks
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
use FindBin;

# Database Path. If you install Taskpony as a SystemD service elsewhere than /opt/taskpony - you'll need to change this.
my $db_path = '/opt/taskpony/db/taskpony.db';    # Path to Sqlite database file internal to docker. If not present, it will be auto created. 
my $bg_path = '/opt/taskpony/static/background.jpg';   # Path to the background picture, if used.

###############################################
# Default configuration. Don't change them here, use /config page.
our $config = {
    cfg_task_pagination_length => 25,           # Number of tasks to show per page 
    cfg_description_short_length => 30,         # Number of characters to show in task list before truncating description (Cosmetic only)
    cfg_list_short_length => 20,                # Number of characters to show in list column in task display before truncating (Cosmetic only)
    cfg_include_datatable_buttons => 'on',      # Include the CSV/Copy/PDF etc buttons at the bottom of each table
    cfg_include_datatable_search => 'on',       # Include the search box at the top right of each table
    cfg_export_all_cols => 'off',               # Export all columns in datatable exports, not just visible ones
    cfg_show_dates_lists => 'on',               # Show just tasks, hide Date and List columns in task list
    cfg_header_colour => 'success',             # Bootstrap 5 colour of pane backgrounds and highlights
    cfg_last_daily_run => 0,                    # Date of last daily run
    cfg_backup_number_to_keep => 7,             # Number of daily DB backups to keep
    cfg_version_check => 'on',                  # Whether to occasionally check for new releases
    cfg_background_image => 'on',
    database_schema_version => 1,               # Don't change this.
    };

###############################################
# Global variables that are used throughout - do not change these.  
my $app_title = 'Taskpony';             # Name of app.
my $app_version = '0.3';               # Version of app
my $database_schema_version = 2;        # Current database schema version. Do not change this, it will be modified during updates.
my $github_version_url = 'https://api.github.com/repos/digdilem/taskpony/releases/latest';  # Used to get latest version for upgrade notification
my $app_releases_page = 'https://github.com/digdilem/taskpony';     # Where new versions are
my $new_version_available = 0;

my $dbh;                        # Global database handle 
my $list_id = 1;                # Current list id
my $list_name;                  # Current list name
my $debug = 0;                  # Set to 1 to enable debug messages to STDERR
my $alert_text = '';            # If set, show this alert text on page load
my $show_completed = 0;         # If set to 1, show completed tasks instead of active ones

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

# Some inline SVG fontawesome icons to prevent including the entire svg map just for a few icons
my $fa_header = q~<svg class="icon" aria-hidden="true" focusable="false" viewBox="0 0 640 640" width="30" height="30">
                <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                ~;

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
my $fa_chart = $fa_header . q~
                    <path fill="currentColor" d="M128 128C128 110.3 113.7 96 96 96C78.3 96 64 110.3 64 128L64 464C64 508.2 99.8 544 144 544L544 544C561.7 544 576 529.7 576 512C576 494.3 561.7 480 544 480L144 480C135.2 480 128 472.8 128 464L128 128zM534.6 214.6C547.1 202.1 547.1 181.8 534.6 169.3C522.1 156.8 501.8 156.8 489.3 169.3L384 274.7L326.6 217.4C314.1 204.9 293.8 204.9 281.3 217.4L185.3 313.4C172.8 325.9 172.8 346.2 185.3 358.7C197.8 371.2 218.1 371.2 230.6 358.7L304 285.3L361.4 342.7C373.9 355.2 394.2 355.2 406.7 342.7L534.7 214.7z"/>
                    </svg>~;
my $fa_edit = $fa_header . q~
                    <path fill="currentColor" d="M505 122.9L517.1 135C526.5 144.4 526.5 159.6 517.1 168.9L488 198.1L441.9 152L471 122.9C480.4 113.5 495.6 113.5 504.9 122.9zM273.8 320.2L408 185.9L454.1 232L319.8 366.2C316.9 369.1 313.3 371.2 309.4 372.3L250.9 389L267.6 330.5C268.7 326.6 270.8 323 273.7 320.1zM437.1 89L239.8 286.2C231.1 294.9 224.8 305.6 221.5 317.3L192.9 417.3C190.5 425.7 192.8 434.7 199 440.9C205.2 447.1 214.2 449.4 222.6 447L322.6 418.4C334.4 415 345.1 408.7 353.7 400.1L551 202.9C579.1 174.8 579.1 129.2 551 101.1L538.9 89C510.8 60.9 465.2 60.9 437.1 89zM152 128C103.4 128 64 167.4 64 216L64 488C64 536.6 103.4 576 152 576L424 576C472.6 576 512 536.6 512 488L512 376C512 362.7 501.3 352 488 352C474.7 352 464 362.7 464 376L464 488C464 510.1 446.1 528 424 528L152 528C129.9 528 112 510.1 112 488L112 216C112 193.9 129.9 176 152 176L264 176C277.3 176 288 165.3 288 152C288 138.7 277.3 128 264 128L152 128z"/></svg>~;                    

# Smaller FA icons for inline use in tables
my $fa_header_small = q~<svg class="icon" aria-hidden="true" focusable="false" viewBox="0 0 640 640" width="20" height="20">
                <!--!Font Awesome Free v7.1.0 by @fontawesome - https://fontawesome.com License - https://fontawesome.com/license/free Copyright 2025 Fonticons, Inc.-->
                ~;                    
my $fa_link_slash = $fa_header_small . q~
                    <path fill="currentColor" d="M73 39.1C63.6 29.7 48.4 29.7 39.1 39.1C29.8 48.5 29.7 63.7 39 73.1L567 601.1C576.4 610.5 591.6 610.5 600.9 601.1C610.2 591.7 610.3 576.5 600.9 567.2L478.9 445.2C483.1 441.8 487.2 438.1 491 434.3L562.1 363.2C591.4 333.9 607.9 294.1 607.9 252.6C607.9 166.2 537.9 96.1 451.4 96.1C414.1 96.1 378.3 109.4 350.1 133.3C370.4 143.4 388.8 156.8 404.6 172.8C418.7 164.5 434.8 160.1 451.4 160.1C502.5 160.1 543.9 201.5 543.9 252.6C543.9 277.1 534.2 300.6 516.8 318L445.7 389.1C441.8 393 437.6 396.5 433.1 399.6L385.6 352.1C402.1 351.2 415.3 337.7 415.8 321C415.8 319.7 415.8 318.4 415.8 317.1C415.8 230.8 345.9 160.2 259.3 160.2C240.1 160.2 221.4 163.7 203.8 170.4L73 39.1zM257.9 224C258.5 224 259 224 259.6 224C274.7 224 289.1 227.7 301.7 234.2C303.5 235.4 305.3 236.5 307.2 237.3C334 253.6 352 283.2 352 316.9C352 317.3 352 317.7 352 318.1L257.9 224zM378.2 480L224 325.8C225.2 410.4 293.6 478.7 378.1 479.9zM171.7 273.5L126.4 228.2L77.8 276.8C48.5 306.1 32 345.9 32 387.4C32 473.8 102 543.9 188.5 543.9C225.7 543.9 261.6 530.6 289.8 506.7C269.5 496.6 251 483.2 235.2 467.2C221.2 475.4 205.1 479.8 188.5 479.8C137.4 479.8 96 438.4 96 387.3C96 362.8 105.7 339.3 123.1 321.9L171.7 273.3z"/></svg>~;
my $fa_info_small = $fa_header_small . q~
                    <path fill="currentColor" d="M320 576C461.4 576 576 461.4 576 320C576 178.6 461.4 64 320 64C178.6 64 64 178.6 64 320C64 461.4 178.6 576 320 576zM288 224C288 206.3 302.3 192 320 192C337.7 192 352 206.3 352 224C352 241.7 337.7 256 320 256C302.3 256 288 241.7 288 224zM280 288L328 288C341.3 288 352 298.7 352 312L352 400L360 400C373.3 400 384 410.7 384 424C384 437.3 373.3 448 360 448L280 448C266.7 448 256 437.3 256 424C256 410.7 266.7 400 280 400L304 400L304 336L280 336C266.7 336 256 325.3 256 312C256 298.7 266.7 288 280 288z"/>
                    </svg>~;
my $fa_repeat_small = $fa_header_small . q~
                    <path fill="currentColor"  d="M534.6 182.6C547.1 170.1 547.1 149.8 534.6 137.3L470.6 73.3C461.4 64.1 447.7 61.4 435.7 66.4C423.7 71.4 416 83.1 416 96L416 128L256 128C150 128 64 214 64 320C64 337.7 78.3 352 96 352C113.7 352 128 337.7 128 320C128 249.3 185.3 192 256 192L416 192L416 224C416 236.9 423.8 248.6 435.8 253.6C447.8 258.6 461.5 255.8 470.7 246.7L534.7 182.7zM105.4 457.4C92.9 469.9 92.9 490.2 105.4 502.7L169.4 566.7C178.6 575.9 192.3 578.6 204.3 573.6C216.3 568.6 224 556.9 224 544L224 512L384 512C490 512 576 426 576 320C576 302.3 561.7 288 544 288C526.3 288 512 302.3 512 320C512 390.7 454.7 448 384 448L224 448L224 416C224 403.1 216.2 391.4 204.2 386.4C192.2 381.4 178.5 384.2 169.3 393.3L105.3 457.3z"/></svg>~;
my $fa_comment_small = $fa_header_small . q~
                    <path fill="currentColor" d="M115.9 448.9C83.3 408.6 64 358.4 64 304C64 171.5 178.6 64 320 64C461.4 64 576 171.5 576 304C576 436.5 461.4 544 320 544C283.5 544 248.8 536.8 217.4 524L101 573.9C97.3 575.5 93.5 576 89.5 576C75.4 576 64 564.6 64 550.5C64 546.2 65.1 542 67.1 538.3L115.9 448.9zM153.2 418.7C165.4 433.8 167.3 454.8 158 471.9L140 505L198.5 479.9C210.3 474.8 223.7 474.7 235.6 479.6C261.3 490.1 289.8 496 319.9 496C437.7 496 527.9 407.2 527.9 304C527.9 200.8 437.8 112 320 112C202.2 112 112 200.8 112 304C112 346.8 127.1 386.4 153.2 418.7z"/></svg>~;
my $fa_star_off = $fa_header_small . q~
                    <path fill="currentColor" d="M528.1 171.5L382 150.2 316.7 17c-11.7-23.6-45.6-23.9-57.4 0L194 150.2 47.9 171.5c-26.2 3.8-36.7 36.1-17.7 54.6l105.7 103-25 145.5c-4.5 26.2 23 46 46.4 33.7L288 439.6l130.7 68.7c23.4 12.3 50.9-7.5 46.4-33.7l-25-145.5 105.7-103c19-18.5 8.5-50.8-17.7-54.6zM388.6 312.3l23.7 138.1L288 385.4l-124.3 65.1 23.7-138.1-100.6-98 139-20.2 62.2-126 62.2 126 139 20.2-100.6 98z"/>
                    </svg>~;
my $fa_star_on = $fa_header_small . q~
                    <path fill="currentColor" d="M259.3 17.8L194 150.2 47.9 171.5c-26.2 3.8-36.7 36.1-17.7 54.6l105.7 103-25 145.5c-4.5 26.3 23 46 46.4 33.7L288 439.6l130.7 68.7c23.4 12.3 50.9-7.5 46.4-33.7l-25-145.5 105.7-103c19-18.5 8.5-50.8-17.7-54.6L382 150.2 316.7 17c-11.7-23.6-45.6-23.9-57.4 0z"/>
                    </svg>~;
my $fa_goto = $fa_header_small . q~
                    <path fill="currentColor" d="M409 337C418.4 327.6 418.4 312.4 409 303.1L265 159C258.1 152.1 247.8 150.1 238.8 153.8C229.8 157.5 224 166.3 224 176L224 256L112 256C85.5 256 64 277.5 64 304L64 336C64 362.5 85.5 384 112 384L224 384L224 464C224 473.7 229.8 482.5 238.8 486.2C247.8 489.9 258.1 487.9 265 481L409 337zM416 480C398.3 480 384 494.3 384 512C384 529.7 398.3 544 416 544L480 544C533 544 576 501 576 448L576 192C576 139 533 96 480 96L416 96C398.3 96 384 110.3 384 128C384 145.7 398.3 160 416 160L480 160C497.7 160 512 174.3 512 192L512 448C512 465.7 497.7 480 480 480L416 480z"/></svg>~;


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

    calculate_stats();                    # Update stats hashref if needed

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
    if ($req->path eq "/favicon.ico") {
        # Redirect to ./static/favicon.ico
        $res->redirect('./static/favicon.ico');
        return $res->finalize;
        } # End /favicon.ico

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

            debug("Task $task_id marked as complete");
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
                debug("Task $task_id marked as active again");
                add_alert("Task #$task_id re-activated.");
                $stats->{tasks_completed_today} -= 1; 
            }
        }
        $res->redirect('/?sc=1'); # Redirect back to completed tasks view and show completed tasks, as we probably came from there
        return $res->finalize;
        } # End /ust

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

                $html .= start_card("Edit Task #$task_id - $task_status", $fa_edit, 0);

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
                                            <span data-bs-toggle="tooltip" title="When you complete this task, it will automatically become active again after the selected number of days.">
                                                $fa_info_small
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
                                                    <span data-bs-toggle="tooltip" title="How many days after completion should this task re-activate? Range 1-365">
                                                        $fa_info_small
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
        $html .= start_card('Lists Management', $fa_list, 0);
        $html .= qq~  
                            <div class="table-responsive">
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
                                        <a href-"/?lid=$list->{'id'}" class="btn-sm text-white text-decoration-none" data-bs-toggle="tooltip" data-bs-placement="top" title="Jump to list $title">
                                            $fa_goto
                                        </a>
                                        <button type="button" class="btn btn-sm btn-danger" data-bs-toggle="modal" data-bs-target="#deleteListModal" data-list-id="$list->{'id'}" data-list-title="$title" data-active-tasks="$active_count">Delete</button>
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
        $html .= start_mini_card('Add New List', $fa_list);
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
                $html .= start_card("Edit List", $fa_list, 0);
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
                        if ($key =~ 'cfg_include_datatable_|cfg_export_all_cols|cfg_show_dates_lists|cfg_version_check|cfg_include_datatable_search|cfg_background_image') {
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


        my $html .= header();

        $html .= start_card("Settings", $fa_gear, 0);
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
                    $html .= config_show_option('cfg_include_datatable_search','Display Search Box','Show the search box at the top right of the Tasks table','check',0,0);
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

            <button class="btn btn-primary">Save Settings</button>

            </div>

            ~;

            # End the main form
            $html .= qq~
                        </div>
                    </div>
                </div>
            </form>
            ~;

            # Start second form for the background image upload

            $html .= qq~
            <hr>

            <form method="post" action="/background_set" enctype="multipart/form-data">
            <div class="d-flex flex-wrap align-items-center justify-content-between p-3 bg-dark text-white rounded gap-3">
                
                <label for="background" class="form-label mb-0 flex-grow-1"  
                    data-bs-toggle="tooltip"
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
                        required
                    >
                    <button type="submit" class="btn btn-primary text-nowrap">
                        Go
                    </button>
                </div>
            </div>

            <div class="form-text mt-1">
                Upload a JPG to replace the current background image.
            </div>
            </form>
            ~;

#             # Row Three
#             $html .= qq~

#             <div class="col">
#             3 of 3
#             </div>

#             ~;


#             # Row Four
#             $html .= qq~

#             <div class="col">
# 4 of 4
#             </div>

#             ~;

       






# <div class="col-12 mt-3">
#   <button class="btn btn-primary">Save Settings</button>
# </div>

# </form>

# <br/> 









                    



#                     </div>
#                 </div>
#             </div>
#         </div>                    
        #~;

        $html .= footer();
        $res->body($html);
        return $res->finalize;
        } # End /config

        ###############################################
        # Show configuration page
        # my $html .= header();

        # $html .= start_card("Settings", $fa_gear, 0);
        # $html .= qq~
        #                  <form method="post" action="/config" style="display:inline;">

        #                     <input type="hidden" name="save_config" value="true">

        #                     <!-- TOGGLE ROW cfg_show_dates_lists -->
        #                     <div class="mb-3">
        #                         <div class="d-flex justify-content-between align-items-center">
        #                         <span class="config-label">
        #                             Show Dates and Lists in Tasks Table
        #                             <span data-bs-toggle="tooltip" title="Show the Dates and Lists columns in the Tasks table, showing just Task names"> 
        #                                 $fa_info_small
        #                             </span> 
        #                         </span>
        #                         <div class="form-check form-switch m-0">
        #                         <input class="form-check-input" type="checkbox" name="cfg_show_dates_lists" 
        #                             id="autoUpdateToggle"
        #                             ~;
        #                             # Precheck this if set
        #                             if ($config->{'cfg_show_dates_lists'} eq 'on') { $html .= " checked "; }

        #                             $html .= qq~
        #                             >
        #                         </div>
        #                         </div>
        #                     </div>

        #                     <!-- TOGGLE ROW cfg_include_datatable_search -->
        #                     <div class="mb-3">
        #                         <div class="d-flex justify-content-between align-items-center">
        #                         <span class="config-label">
        #                             Display Search Box
        #                             <span data-bs-toggle="tooltip" title="Display the search box at the top right of the tasks table"> 
        #                                 $fa_info_small
        #                             </span> 
        #                         </span>
        #                         <div class="form-check form-switch m-0">
        #                         <input class="form-check-input" type="checkbox" name="cfg_include_datatable_search" 
        #                             id="autoUpdateToggle"
        #                             ~;
        #                             # Precheck this if set
        #                             if ($config->{'cfg_include_datatable_search'} eq 'on') { $html .= " checked "; }

        #                             $html .= qq~
        #                             >
        #                         </div>
        #                         </div>
        #                     </div>

        #                     <!-- TOGGLE ROW cfg_include_datatable_buttons -->
        #                     <div class="mb-3">
        #                         <div class="d-flex justify-content-between align-items-center">
        #                         <span class="config-label">                                    
        #                             Display export buttons
        #                             <span data-bs-toggle="tooltip" title="Display the export buttons at the end of the Tasks list - Copy, CSV, PDF, etc">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>
        #                         <div class="form-check form-switch m-0">
        #                         <input class="form-check-input" type="checkbox" name="cfg_include_datatable_buttons" 
        #                             id="autoUpdateToggle"
        #                             ~;

        #                             # Precheck this if set
        #                             if ($config->{'cfg_include_datatable_buttons'} eq 'on') { $html .= " checked "; }

        #                             $html .= qq~
        #                             >
        #                         </div>
        #                         </div>
        #                     </div>

        #                     <!-- TOGGLE ROW cfg_export_all_cols -->
        #                     <div class="mb-3">
        #                         <div class="d-flex justify-content-between align-items-center">
        #                         <span class="config-label">                                    
        #                             Export date and list
        #                             <span data-bs-toggle="tooltip" title="When using the export buttons, $app_title will normally just export the Task name. Enable this to include the date and list for each task">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>
        #                         <div class="form-check form-switch m-0">
        #                         <input class="form-check-input" type="checkbox" name="cfg_export_all_cols" 
        #                             id="autoUpdateToggle"
        #                             ~;

        #                             # Precheck this if set
        #                             if ($config->{'cfg_export_all_cols'} eq 'on') { $html .= " checked "; }

        #                             $html .= qq~
        #                             >
        #                         </div>
        #                         </div>
        #                     </div>

        #                     <!-- TOGGLE ROW cfg_version_check -->
        #                     <div class="mb-3">
        #                         <div class="d-flex justify-content-between align-items-center">
        #                         <span class="config-label">                                    
        #                             Check for new versions
        #                             <span data-bs-toggle="tooltip" title="If checked, Taskpony will occasionally check for new versions of itself and show a small badge in the footer if one is available">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>
        #                         <div class="form-check form-switch m-0">
        #                         <input class="form-check-input" type="checkbox" name="cfg_version_check" 
        #                             id="autoUpdateToggle"
        #                             ~;

        #                             # Precheck this if set
        #                             if ($config->{'cfg_version_check'} eq 'on') { $html .= " checked "; }

        #                             $html .= qq~
        #                             >
        #                         </div>
        #                         </div>
        #                     </div>

        #                     <!-- TOGGLE ROW cfg_background_image -->
        #                     <div class="mb-3">
        #                         <div class="d-flex justify-content-between align-items-center">
        #                         <span class="config-label">                                    
        #                             Enable background image
        #                             <span data-bs-toggle="tooltip" title="If enabled, an JPG can be uploaded through this form below and will be used as a background">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>
        #                         <div class="form-check form-switch m-0">
        #                         <input class="form-check-input" type="checkbox" name="cfg_background_image" 
        #                             id="autoUpdateToggle"
        #                             ~;

        #                             # Precheck this if set
        #                             if ($config->{'cfg_background_image'} eq 'on') { $html .= " checked "; }

        #                             $html .= qq~
        #                             >
        #                         </div>
        #                         </div>
        #                     </div>


        #                     <!-- PICKLIST row cfg_header_colour -->
        #                     <div class="mb-3">
        #                         <span class="config-label">                                    
        #                             Title Background Colour
        #                             <span data-bs-toggle="tooltip" title="Select colour for panel header backgrounds">
        #                                 $fa_info_small
        #                             </span>
        #                         <span class="badge bg-$config->{cfg_header_colour}">Currently '$config->{cfg_header_colour}'</span>
        #                         </span>
                                
        #                         <div>
        #                             <select class="form-select" id="themeColor" name="cfg_header_colour">                                        
        #                                 <option value="$config->{cfg_header_colour}" class="bg-$config->{cfg_header_colour} text-white">Current choice</option>
        #                                 <option value="primary" class="bg-primary text-white">Primary</option>
        #                                 <option value="secondary" class="bg-secondary text-white">Secondary</option>
        #                                 <option value="success" class="bg-success text-white">Success</option>
        #                                 <option value="danger" class="bg-danger text-white">Danger</option>
        #                                 <option value="warning" class="bg-warning text-dark">Warning</option>
        #                                 <option value="info" class="bg-info text-dark">Info</option>
        #                                 <option value="light" class="bg-light text-dark">Light</option>
        #                                 <option value="dark" class="bg-dark text-white">Dark</option>
        #                             </select>
        #                         </div>
        #                     </div>

        #                     <!-- NUMBER ROW cfg_backup_number_to_keep -->
        #                     <div class="mb-3">
        #                         <span class="config-label">                                    
        #                             Number of daily backups to keep
        #                             <span data-bs-toggle="tooltip" title="Each day, $app_title makes a backup of its database. This setting controls how many days worth of backups to keep. Older backups will be deleted automatically. Range 1-100">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>

        #                         <input type="number" class="form-control" 
        #                             value="$config->{cfg_backup_number_to_keep}" 
        #                             name="cfg_backup_number_to_keep"
        #                             min="1" max="100">
        #                     </div>

        #                     <!-- NUMBER ROW cfg_task_pagination_length -->
        #                     <div class="mb-3">
        #                         <span class="config-label">                                    
        #                             Number of Tasks to show on each page
        #                             <span data-bs-toggle="tooltip" title="How many tasks to show on each page before paginating. Range 3-1000">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>

        #                         <input type="number" class="form-control" 
        #                             value="$config->{cfg_task_pagination_length}" 
        #                             name="cfg_task_pagination_length"
        #                             min="3" max="1000">
        #                     </div>

        #                     <!-- NUMBER ROW cfg_description_short_length -->
        #                     <div class="mb-3">
        #                         <span class="config-label">                                    
        #                             Max length of popup task description
        #                             <span data-bs-toggle="tooltip" title="Maximum characters to display of the popup Task description in the Task list before truncating it. Range 3-1000">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>
        #                         <input type="number" class="form-control" 
        #                             value="$config->{cfg_description_short_length}" 
        #                             name="cfg_description_short_length"
        #                             min="3" max="1000">
        #                     </div>

        #                     <!-- NUMBER ROW cfg_description_short_length -->
        #                     <div class="mb-3">
        #                         <span class="config-label">                                    
        #                             Max length of List name in Tasks list
        #                             <span data-bs-toggle="tooltip" title="Maximum characters to display of the List title in the rightmost column before truncating it in the Tasks list. Range 1-100">
        #                                 $fa_info_small
        #                             </span>
        #                         </span>

        #                         <input type="number" class="form-control" 
        #                             value="$config->{cfg_list_short_length}" 
        #                             name="cfg_list_short_length"
        #                             min="1" max="100">
        #                     </div>

        #                     <div class="col-12">
        #                         <button class="btn btn-primary">Save Settings</button>
        #                     </div>


        #                 </form>


        #                 <form method="post" action="/background_set" enctype="multipart/form-data">
        #                 <div class="mb-3">
        #                     <label for="background" class="form-label">
        #                     Change the background image
        #                     </label>
        #                     <input
        #                     class="form-control"
        #                     type="file"
        #                     id="background"
        #                     name="background"
        #                     accept="image/jpeg"
        #                     required
        #                     >
        #                     <div class="form-text">
        #                     Upload a JPG to  replace the current background image.
        #                     </div>
        #                 </div>

        #                 <button type="submit" class="btn btn-primary">
        #                     Upload background
        #                 </button>
        #                 </form>

        #             </div>
        #         </div>
        #     </div>
        # </div>                    
        # ~;

        # $html .= footer();
        # $res->body($html);
        # return $res->finalize;
        # } # End /config

        ###############################################
        # Stats page - show calculated statistics
        if ($req->path eq "/stats") {
            my $html = header();
            $html .= start_card('Statistics', $fa_chart, 0);

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
        }

    ###############################################
    # End named paths

    ###############################################
    # /background_set  = Receive new background upload
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

#        $upload->copy_to("/opt/taskpony/static/background.jpg")  or return [500, [], ['Save failed']];

 # Source temp file provided by Plack
    my $src = $upload->path
        or return [500, [], ['Upload has no temp path']];

    # Atomic write
    my $tmp = "$bg_path.tmp";

    copy($src, $tmp)
        or return [500, [], ["Copy failed: $!"]];

    rename $tmp, $bg_path
        or return [500, [], ["Rename failed: $!"]];


        add_alert("Background image updated");
        return [302, [ Location => '/config' ], []];
    } # End /background_set

    ###############################################
    # Default home/tasklist page - If no other paths have taken the request then land here, list tasks and the quickadd form

    # /?delete_task=nn - Delete task nn 
    my $delete_task = $req->param('delete_task') // 0;        
    if ($delete_task > 0) {
        my $sth = $dbh->prepare('DELETE FROM TasksTb WHERE id = ?');
        eval { $sth->execute($delete_task); 1 } or print STDERR "WARN: Delete TasksTb.id=$delete_task failed: $@";
        add_alert("Task #$delete_task deleted.");
        $res->redirect('/'); # Redirect back to default page
        return $res->finalize;
        }

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
        }

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
                "UPDATE ListsTb SET Title = 'All Tasks' WHERE Title = 'All Lists';",        # Change name of 'All Lists' to 'All Tasks'
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
    </style>

    </head>
    <body 
        class="text-white d-flex flex-column min-vh-100"
        ~;

    if ($config->{'cfg_background_image'} eq 'on') {   # Show a background if enabled. Use the mtime of the file to trigger a cache reload by the client
        my $bg_mtime = (stat("./static/background.jpg"))[9] || time();  # 
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
                        <img src="/static/taskpony-logo.png" width="82" height="82">
                        <h3 class="mb-0">
                            <a href="/" class="text-white text-decoration-none">
                                $app_title
                            </a>
                        </h3>
                        ~;
    
    # Add the list selection pulldown
    $html .= list_pulldown($list_id);  

    $html .= qq~
                    </div>
                    <div class="btn-group" role="group">

                        <a href="/lists"
                            class="btn btn-sm btn-secondary d-inline-flex align-items-center"
                            data-bs-toggle="tooltip" title="Manage Lists" >
                            $fa_list
                        </a>

                        <a href="/stats"
                            class="btn btn-sm btn-secondary d-inline-flex align-items-center justify-content-center btn-icon"
                            data-bs-toggle="tooltip" title="Statistics" >
                            $fa_chart
                        </a>

                        <a href="/config"
                            class="btn btn-sm btn-secondary d-inline-flex align-items-center justify-content-center btn-icon"
                            data-bs-toggle="tooltip" title="Settings" >
                            $fa_gear
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
        <br>
        </div>
        </div>
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
                "paging":   true,
                "ordering": true,
                "info":     true,
                initComplete: function () { 
                    \$('#tasks').removeClass('dt-hidden'); 
                    \$('#hideUntilShow').removeClass('d-none'); 
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
    }

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
        <table id="tasks" class="display hover table-striped dt-hidden" style="width:90%">
            <thead>
                <tr>
                    <th>&nbsp;</th>
                    <th>Title</th>
        ~;

        # Show or hide date and list columns based on config
        if ($config->{'cfg_show_dates_lists'} eq 'on') {

            if ($status == 1) {  # Active tasks. Show added date
                $html .= "            <th>Added</th>\n";
                } else { # Completed tasks. Show completed date
                $html .= "<th>Completed</th>\n";
                }

            $html .= qq~
                    <th>List</th>
                    ~;
            } 
        
        # Close row
        $html .= qq~
                </tr>
            </thead>
            <tbody>
            ~;

    # Loop through each task and output a row for each. Add data-order sso that Datatables can sort by actual date value instead of human friendly string
    while (my $a = $sth->fetchrow_hashref()) {
        my $friendly_date = qq~
            <td data-order="$a->{'AddedDate'}">
                <a href="#" class="text-reset text-decoration-none" data-bs-toggle="tooltip" title="Added at: $a->{'AddedDate'}">
                ~
                . human_friendly_date($a->{'AddedDate'}) . qq~</a> 
            </td>
            ~;

        if ($status != 1) { # Completed tasks, show CompletedDate instead
            $friendly_date = qq~
            <td data-order="$a->{'CompletedDate'}">
                <a href="#" class="text-reset text-decoration-none" data-bs-toggle="tooltip" title="Completed at: $a->{'CompletedDate'}">
                ~
                . human_friendly_date($a->{'CompletedDate'}) . qq~</a>
            </td>
            ~;
            }

        my $checkbox = '';  # Default empty
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
            $title_link .= qq~<span class="text-$config->{cfg_header_colour}" data-bs-toggle="tooltip" title="This task belongs to a deleted list">$fa_link_slash</span> ~;
            }

        # Add a repeat icon if the task is recurring
        if (defined $a->{'IsRecurring'} && $a->{'IsRecurring'} eq 'on') {
            $title_link .= qq~<span class="text-$config->{cfg_header_colour}" data-bs-toggle="tooltip" title="This is a repeating task. Once completed, it will reactivate after $a->{RecurringIntervalDay} days">$fa_repeat_small</span> ~;
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
                    data-bs-toggle="tooltip" 
                    title="$description"
                    >                   
                    $title
                    ~;
            if ($description) {
                $title_link .= qq~<span class="text-$config->{cfg_header_colour}">&nbsp; $fa_comment_small</span> ~;
                }
            $title_link .= qq~
                    </a>
                     ~;
            } 

        # Completed tasks. Show strikethrough title and button to mark uncompleted
        if ($status == 2) { # Completed tasks
            $title_link .= qq~
                    <a 
                    href="/edittask?id=$a->{'id'}"
                    class="text-white text-decoration-none" 
                    data-bs-toggle="tooltip" 
                    title="$description Completed ~ . human_friendly_date($a->{'CompletedDate'}) . qq~"
                    >
                    $title
                    </a>
                     ~;

            $checkbox .= qq~
                <a href="/ust?task_id=$a->{'id'}&sc=1" class="btn btn-sm btn-secondary" title="Mark as uncompleted">
                $fa_rotate_left
                </a>
                ~;
            }
        
        # Output the table row
        $html .= qq~
            <tr>
                <td>$checkbox</td>
                <td>$title_link</td>
                ~;

        # Show or hide date and list column header based on config var cfg_show_dates_lists
        if ($config->{'cfg_show_dates_lists'} eq 'on') {
            $html .= qq~
                $friendly_date
                <td>
                ~;

            if ($list_deleted != 0) { # List is deleted, no link
                $html .= "$list_title</td>\n";
                } else {
                $html .= qq~
                    <a 
                    href="/?lid=$a->{'ListId'}"
                    class="text-white text-decoration-none" 
                    data-bs-toggle="tooltip" 
                    title="Jump to $a->{'ListTitle'}"
                    >
                    $list_title
                </td>
                ~;
                }
            }

        # Close the row
        $html .= qq~
        </tr>
        ~;
    } # End tasks loop

    # Close table
    $html .= qq~
            </tbody>
        </table>
        <br><br>
        ~;

    # Display a link to toggle between showing completed/active tasks
    if ($show_completed == 0) {
        my $cnt_completed_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 2 AND ListId = $list_id");
        $html .= qq~
            <a href="/?sc=1" class="btn btn-secondary btn d-none" id="hideUntilShow">Show $cnt_completed_tasks completed tasks in '$list_name'</a>
            ~;
        } else {
        my $cnt_active_tasks = single_db_value("SELECT COUNT(*) FROM TasksTb WHERE Status = 1 AND ListId = $list_id");

        $html .= qq~
            <a href="/" class="btn btn-secondary btn d-none" id="hideUntilShow">Show $cnt_active_tasks active tasks in '$list_name'</a>
            ~;
        }

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

    my $html = qq~ <div class="card shadow-sm"> ~;

    if ($table_card == 1) { $html = qq~ <div class="card shadow-sm d-none" id="hideUntilShow" >~; }  # If a table, hide the whole card until loaded

    $html .= qq~
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
    } # End start_card()

###############################################
# As above, but smaller. Used for second cards on a page (Eg: Add List)
sub start_mini_card {
    my $card_title = shift || 'Title Missing';
    my $card_icon = shift || '';
    my $html = qq~
        <div class="container py-5">
            <div class="row justify-content-center">
                <div class="col-md-8">
                    <div class="card shadow-sm">
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


    # We ran today, so let's update the last run time and return
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
    }

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
            <label class="form-check-label" for="$key" data-bs-toggle="tooltip" title="$description" >
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

  
##############################################
# End Functions

#################################################
# End of file
