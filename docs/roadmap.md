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
  - Ability to undelete Lists from the UI
  - A self refreshing ability when another client changes the database, so it's displaying the latest info.
  - A history table for tasks and actions. Extra detail for recurring tasks, when lists were created, changed etc.
  - Add ability to switch between dark/light modes, or themes.

- Unlikely:
  - A List Template system. This might be where you can create a list with a pre-defined set of Tasks already populating it. This might be useful for for repeatable workflows. This may be overly complex to define, however, and may not be possible within the [Goals](../README.md#goals)
  - Groups / teams / shared and embeddded tasks = Taskpony is a single user Tasks app. There are several good FOSS groupware/multi-user systems around. 
  - Authentication, https = See [security](../README.md#security) for an explanation.
  - Plugins = It's just a Tasks manager, right? If features are needed, they can be baked in. 
