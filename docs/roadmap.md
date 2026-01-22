# Roadmap

Where Taskpony is going.

Some features for the future that may, or may not, be added.

  - Configurable and automated deletion of tasks more than NN days since completion, or delete more than NN recent tasks. (Beware repeatable tasks, will need check so that period can't be less than those and vice versa or a repeating task could get deleted before it has a chance to re-activate.)
  - A priority system. Poss traffic-light 3 dots on each task in list for one-touch change. Low, medium, high? Sorted accordingly?
  - Add default sorting option, rather than just newest-first.
  - Add colour to tasks. (Possibly based on priority, possibly a per-task setting. Beware making things too messy - we don't want fruit salad)
  - Multi-language support.
  - Daily email report. Possibly showing outstanding tasks from Default list and summary stats.
  - Some sort of toggleable daily progress badge "N tasks done today". Unsure of need/benefit.
  - A history table for tasks and actions. Extra detail for recurring tasks, when lists were created, changed etc.
  - Add ability to switch between dark/light modes, or themes.
  - Lists page: Split the three cards into Tabs to keep things above the fold more. Or introduce a quick-add "New List" form like Tasks.
  - Copy to clipboard for task title (would need an icon per line, perhaps configurable, or perhaps a link on the edit task page.

- Unlikely:
  - A List Template system. This might be where you can create a list with a pre-defined set of Tasks already populating it. This might be useful for for repeatable workflows. This may be overly complex to define, however, and may not be possible within the [Goals](../README.md#goals)
  - Groups / teams / multiple users / shared and embeddded tasks = Taskpony is a single user Tasks app. There are several good FOSS groupware/multi-user systems around.
  - Authentication, https = See [security](../README.md#security) for an explanation.
  - Plugins = It's just a Tasks manager, right? If features are needed, they can be baked in.
  - Statistical graphs = This would mean bundling in a graphing library. For something that many users may not use, it's hard to think of this as anything other than bloat.
