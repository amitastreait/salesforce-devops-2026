/**
 * @description Core service class for Employee Onboarding business logic.
 *              Called by trigger handlers and LWC controllers.
 *              Follows the service layer pattern — all DML happens here, not in handlers.
 */
public with sharing class OnboardingService {

    // ─── Default Tasks ────────────────────────────────────────────────────────

    /**
     * @description Creates 4 standard onboarding tasks for each newly inserted
     *              Onboarding Request. Called from OnboardingRequestTriggerHandler.
     * @param requests List of newly inserted Onboarding_Request__c records
     */
    public static void createDefaultTasks(List<Onboarding_Request__c> requests) {
        List<Onboarding_Task__c> tasksToInsert = new List<Onboarding_Task__c>();

        for (Onboarding_Request__c req : requests) {
            Date startDate = req.Start_Date__c;

            tasksToInsert.add(buildTask(req.Id, 'Set up laptop & software access', 'IT',        startDate.addDays(-3)));
            tasksToInsert.add(buildTask(req.Id, 'Issue employee badge & desk assignment', 'Facilities', startDate.addDays(-2)));
            tasksToInsert.add(buildTask(req.Id, 'Complete HR paperwork & benefits enrollment', 'HR', startDate.addDays(-1)));
            tasksToInsert.add(buildTask(req.Id, 'Schedule orientation & compliance training', 'Training', startDate));
        }

        if (!tasksToInsert.isEmpty()) {
            insert tasksToInsert;
        }
    }

    private static Onboarding_Task__c buildTask(Id requestId, String name, String category, Date dueDate) {
        return new Onboarding_Task__c(
            Name                 = name,
            Onboarding_Request__c = requestId,
            Category__c          = category,
            Due_Date__c          = dueDate,
            Is_Completed__c      = false
        );
    }

    // ─── Completion Percentage ────────────────────────────────────────────────

    /**
     * @description Recalculates Completion_Percentage__c on parent Onboarding_Request__c
     *              records after tasks are updated. Called from OnboardingTaskTriggerHandler.
     * @param updatedTasks List of updated Onboarding_Task__c records
     */
    public static void recalculateCompletion(List<Onboarding_Task__c> updatedTasks) {
        Set<Id> requestIds = new Set<Id>();
        for (Onboarding_Task__c task : updatedTasks) {
            requestIds.add(task.Onboarding_Request__c);
        }

        // Query all tasks grouped by parent request
        Map<Id, List<Onboarding_Task__c>> tasksByRequest = new Map<Id, List<Onboarding_Task__c>>();
        for (Onboarding_Task__c task : [
            SELECT Id, Onboarding_Request__c, Is_Completed__c
            FROM   Onboarding_Task__c
            WHERE  Onboarding_Request__c IN :requestIds
        ]) {
            if (!tasksByRequest.containsKey(task.Onboarding_Request__c)) {
                tasksByRequest.put(task.Onboarding_Request__c, new List<Onboarding_Task__c>());
            }
            tasksByRequest.get(task.Onboarding_Request__c).add(task);
        }

        List<Onboarding_Request__c> requestsToUpdate = new List<Onboarding_Request__c>();
        for (Id reqId : tasksByRequest.keySet()) {
            List<Onboarding_Task__c> tasks = tasksByRequest.get(reqId);
            Integer total     = tasks.size();
            Integer completed = 0;
            for (Onboarding_Task__c t : tasks) {
                if (t.Is_Completed__c) completed++;
            }

            Integer pct = (total > 0) ? (Integer)((completed * 100) / total) : 0;
            String  newStatus = (pct == 100) ? 'Completed' : (pct > 0 ? 'In Progress' : 'New');

            requestsToUpdate.add(new Onboarding_Request__c(
                Id                      = reqId,
                Completion_Percentage__c = pct,
                Status__c               = newStatus
            ));
        }

        if (!requestsToUpdate.isEmpty()) {
            update requestsToUpdate;
        }
    }

    // ─── LWC Controller Methods ───────────────────────────────────────────────

    /**
     * @description Returns all active (non-Completed, non-Cancelled) Onboarding Requests.
     *              Used by the onboardingDashboard LWC.
     */
    @AuraEnabled(cacheable=true)
    public static List<Onboarding_Request__c> getActiveRequests() {
        return [
            SELECT Id, Name, Employee_Name__c, Department__c, Status__c,
                   Start_Date__c, Completion_Percentage__c, Assigned_HR__c,
                   Assigned_HR__r.Name
            FROM   Onboarding_Request__c
            WHERE  Status__c NOT IN ('Completed', 'Cancelled')
            ORDER BY Start_Date__c ASC
            LIMIT 200
        ];
    }

    /**
     * @description Returns ALL Onboarding Requests (all statuses) including
     *              their child tasks. Used by the modern onboardingDashboard LWC.
     */
    @AuraEnabled(cacheable=true)
    public static List<Onboarding_Request__c> getAllRequestsWithTasks() {
        return [
            SELECT Id, Name, Employee_Name__c, Department__c, Status__c,
                   Start_Date__c, Completion_Percentage__c, Assigned_HR__c,
                   Assigned_HR__r.Name,
                   (SELECT Id, Name, Category__c, Due_Date__c,
                           Is_Completed__c, Assigned_To__c, Assigned_To__r.Name
                    FROM   Onboarding_Tasks__r
                    ORDER BY Due_Date__c ASC NULLS LAST)
            FROM   Onboarding_Request__c
            ORDER BY Start_Date__c ASC
            LIMIT  500
        ];
    }

    /**
     * @description Creates a new Onboarding Request from the LWC form.
     * @param employeeName   Full name of the new hire
     * @param startDate      First day of work
     * @param department     Department picklist value
     * @return Id of the newly created record
     */
    @AuraEnabled
    public static Id createOnboardingRequest(String employeeName, Date startDate, String department) {
        Onboarding_Request__c request = new Onboarding_Request__c(
            Employee_Name__c = employeeName,
            Start_Date__c    = startDate,
            Department__c    = department,
            Status__c        = 'New'
        );
        insert request;
        return request.Id;
    }

    // ─── Reminder Logic (used by Scheduled Apex) ─────────────────────────────

    /**
     * @description Returns requests starting in exactly 3 days that still have
     *              incomplete tasks. Used by OnboardingReminderScheduler.
     */
    public static List<Onboarding_Request__c> getRequestsNeedingReminder() {
        Date targetDate = Date.today().addDays(3);
        return [
            SELECT Id, Name, Employee_Name__c, Start_Date__c,
                   Assigned_HR__c, Assigned_HR__r.Email,
                   (SELECT Id FROM Onboarding_Tasks__r WHERE Is_Completed__c = FALSE)
            FROM   Onboarding_Request__c
            WHERE  Start_Date__c = :targetDate
            AND    Status__c NOT IN ('Completed', 'Cancelled')
        ];
    }

    /**
     * @description Sends reminder emails to HR for each request with incomplete tasks.
     * @param requests Requests returned by getRequestsNeedingReminder()
     */
    public static void sendReminderEmails(List<Onboarding_Request__c> requests) {
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Onboarding_Request__c req : requests) {
            if (req.Onboarding_Tasks__r.isEmpty()) continue;
            if (req.Assigned_HR__c == null)        continue;

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setTargetObjectId(req.Assigned_HR__c);
            mail.setSaveAsActivity(false);
            mail.setSubject('Action Required: Incomplete Onboarding Tasks for ' + req.Employee_Name__c);
            mail.setPlainTextBody(
                'Hi,\n\n' +
                req.Employee_Name__c + ' starts in 3 days (' + req.Start_Date__c.format() + ').\n' +
                'There are ' + req.Onboarding_Tasks__r.size() + ' incomplete onboarding task(s) remaining.\n\n' +
                'Please review and complete all tasks before the start date.\n\n' +
                'Onboarding Request: ' + req.Name
            );
            emails.add(mail);
        }

        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
    }
}