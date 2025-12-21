# Version History

## 0.01 Initial release, 15th December 2025

## 0.2  Released Christmas, 2025

"Improved orphan handing. Added repeating tasks, stats and database backups. Multiple bugfixes and UI improvements."

- Bugfix: Re-add html_escape() which had previously been merged with sanitize() and change calls to use it when displaying output. This corrects where tasks were stored and displayed with certain characters were made safe that didn't need to be. Quotes, single quotes, ampersands etc.
- UX: Renamed "All Lists" to "All Tasks" @halcyonloon https://github.com/digdilem/taskpony/issues/1
- UX: Removed blue link colour for dates in main list. (Link only there for tooltip on hover)
- UX: Orphaned tasks in "All Tasks" list now have a new in-line icon before the task title, and their List name changed to "[--No List--]" (if List and dates enabled)
- UX: List Management - when deleting a list, user is now presented with several options so they can decide what happens to any tasks within that list.
- UX: Clicking the task's List in the "All tasks" List now jumps to that List.
- UX: Top-right buttons: "Lists" changed to icon. Stats button added. All benefit from description popups. Slight change to div to wrap them onto second line for small devices as they were flowing off screen. Slight tweak to background colour to match icon.
- UX: "N tasks completed today!" added to task completed banner
- Feature: Local stats calculated. Rate limited to 1/hr to avoid performance hit.
- Feature: /stats page added with some basic statistics.
- Change: Config save rewritten to make it easier to expand in the future.
- Feature: Daily backups of the database are now created. Number of them is configurable in /settings
- Feature: Recurring tasks added. @DorkyP https://github.com/digdilem/taskpony/issues/2
- Change: Daily functions call added for backups and repeating task management.
- Documentation: Moved various blocks of documentation into their own file for neatness and future upgrade ability.

