# Schema

Database schema: Taskpony uses Sqlite for simplicity and a small footprint. 

Version upgrades will be handled automtically by Taskpony when it detects that the hardcoded version is higher than the current database version. This check is done on app start.

The schema is below.

/ TasksDb

    / TasksTb    
        id
        Status (1 Active, 2 Completed)
        Title
        Description
        AddedDate = When created
        CompletedDate = When set as done. Is reset if task unset
        StartDate =  Tasks can be deferred    
        ListId = List this task belongs to
    Schema 2+:
        IsRecurring = on|off  Whether a task is set to repeat  
        RecurringIntervalDay = Number of days after a task is completed before it is set active
    
    / ListsTb  (List of Lists)
        id
        Title
        AddedDate
        DeletedDate = NULL if active, otherwise when deleted
        Description
        Colour = TBC
        IsDefault = The default list is sorted top of the picklist regardless of its alphaness.
        
    /ConfigTb  (Configuration)
        (Various key pairs of configuration values and persistent internal states. Many configurable on the /config page)
        id
        key
        value 


