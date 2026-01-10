# Web Paths:

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

- /editlist
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

  - /padd = Receive form to add a new project

  - /ust ?task_id=N = Unset a task from completed to active.


    /api/pong
        Returns "pong" and status code 200 - useful for "Are you alive?" checks



