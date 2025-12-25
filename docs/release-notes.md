# Taskpony Version History


## 0.3  

Task List:
- You can now upload a JPG for a page background. There is a toggle in /config and a new upload form. 
- "Show completed/active tasks" button now includes the number of tasks that will be shown.
- Tasks that have a description now show an info icon to indicate that they can be hovered to see it.
- Lots of work gone into reducing page flicker on load. Task table now hides until Datatables is ready. You could see a flicker sometimes on page load with larger lists where it was re-rendered, and that's now gone. There's a few other places where this the UI has been improved.
- Settings page has been reworked for better clarity and future maintenance.

## 0.2d  Released Christmas, 2025

- Fix a couple of regressions. favicon displaying, and rounded bottoms.


## 0.2c  Released Christmas, 2025

"Improved orphan handing. Added repeating tasks, stats and database backups. Multiple bugfixes and UI improvements."

### To upgrade v.0.01 to v.0.2, follow the [Upgrade Instructions](../README.md#upgrading)

### Changes

- Bugfix: Re-add html_escape() which had previously been merged with sanitize() and change calls to use it when displaying output. This corrects where tasks were stored and displayed with certain characters were made safe that didn't need to be. Quotes, single quotes, ampersands etc.

- UX: Renamed "All Lists" to "All Tasks" @halcyonloon https://github.com/digdilem/taskpony/issues/1
- UX: Removed blue link colour for dates in main list. (Link only there for tooltip on hover)
- UX: Orphaned tasks in "All Tasks" list now have a new in-line icon before the task title, and their List name changed to "[--No List--]" (if List and dates enabled)
- UX: List Management - when deleting a list, user is now presented with several options so they can decide what happens to any tasks within that list.
- UX: Clicking the task's List in the "All tasks" List now jumps to that List.
- UX: Top-right buttons: "Lists" changed to icon. Stats button added. All benefit from description popups. Slight change to div to wrap them onto second line for small devices as they were flowing off screen. Slight tweak to background colour to match icon.
- UX: "N tasks completed today!" added to task completed banner and similar for tasks added.

- Feature: Local stats calculated. Rate limited to 1/hr to avoid performance hit.
- Feature: /stats page added with some basic statistics.

- Feature: Daily backups of the database are now created. Number of them is configurable in /settings
- Feature: Recurring tasks added. @DorkyP https://github.com/digdilem/taskpony/issues/2

- Change: Config save rewritten to make it easier to expand in the future.
- Change: Daily functions call added for backups and repeating task management.

- Documentation: Moved various blocks of documentation into their own file for neatness and future upgrade ability.

## 0.01 Initial release, 15th December 2025
