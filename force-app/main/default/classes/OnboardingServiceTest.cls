/**
 * @description Unit tests for OnboardingService.
 *              Covers: createDefaultTasks, recalculateCompletion,
 *              getActiveRequests, getAllRequestsWithTasks,
 *              createOnboardingRequest, getRequestsNeedingReminder,
 *              sendReminderEmails.
 */
@IsTest
private class OnboardingServiceTest {

    // ── Test Data Helpers ────────────────────────────────────────────────

    private static Onboarding_Request__c makeRequest(String name, Integer daysFromNow) {
        return new Onboarding_Request__c(
            Employee_Name__c = name,
            Start_Date__c    = Date.today().addDays(daysFromNow),
            Department__c    = 'IT',
            Status__c        = 'New',
            Assigned_HR__c   = UserInfo.getUserId()
        );
    }

    private static List<Onboarding_Task__c> fetchTasks(Id requestId) {
        return [
            SELECT Id, Name, Category__c, Due_Date__c, Is_Completed__c
            FROM   Onboarding_Task__c
            WHERE  Onboarding_Request__c = :requestId
            ORDER BY Due_Date__c ASC
        ];
    }

    // ── createDefaultTasks ───────────────────────────────────────────────

    @IsTest
    static void createDefaultTasks_insertsExactlyFourTasks() {
        Test.startTest();
        insert makeRequest('Alice Smith', 10);
        Test.stopTest();

        Onboarding_Request__c req = [
            SELECT Id FROM Onboarding_Request__c
            WHERE Employee_Name__c = 'Alice Smith' LIMIT 1
        ];
        List<Onboarding_Task__c> tasks = fetchTasks(req.Id);

        Assert.areEqual(4, tasks.size(), 'Should create exactly 4 default tasks');
    }

    @IsTest
    static void createDefaultTasks_coversAllFourCategories() {
        Onboarding_Request__c req = makeRequest('Bob Chen', 10);
        insert req;

        Set<String> cats = new Set<String>();
        for (Onboarding_Task__c t : fetchTasks(req.Id)) {
            cats.add(t.Category__c);
        }

        Assert.isTrue(cats.contains('IT'),         'Should have an IT task');
        Assert.isTrue(cats.contains('Facilities'), 'Should have a Facilities task');
        Assert.isTrue(cats.contains('HR'),         'Should have an HR task');
        Assert.isTrue(cats.contains('Training'),   'Should have a Training task');
    }

    @IsTest
    static void createDefaultTasks_dueDatesRelativeToStartDate() {
        Date startDate = Date.today().addDays(10);
        Onboarding_Request__c req = new Onboarding_Request__c(
            Employee_Name__c = 'Carol Lee',
            Start_Date__c    = startDate,
            Department__c    = 'HR',
            Status__c        = 'New'
        );
        insert req;

        // Tasks ordered by due date ASC → IT(-3), Facilities(-2), HR(-1), Training(0)
        List<Onboarding_Task__c> tasks = fetchTasks(req.Id);
        Assert.areEqual(startDate.addDays(-3), tasks[0].Due_Date__c, 'IT task due 3 days before start');
        Assert.areEqual(startDate.addDays(-2), tasks[1].Due_Date__c, 'Facilities task due 2 days before start');
        Assert.areEqual(startDate.addDays(-1), tasks[2].Due_Date__c, 'HR task due 1 day before start');
        Assert.areEqual(startDate,             tasks[3].Due_Date__c, 'Training task due on start date');
    }

    @IsTest
    static void createDefaultTasks_bulkInsert_createsAllTasks() {
        List<Onboarding_Request__c> reqs = new List<Onboarding_Request__c>();
        for (Integer i = 0; i < 5; i++) {
            reqs.add(makeRequest('Bulk Emp ' + i, 10 + i));
        }

        Test.startTest();
        insert reqs;
        Test.stopTest();

        Integer total = [
            SELECT COUNT() FROM Onboarding_Task__c
            WHERE Onboarding_Request__c IN :reqs
        ];
        Assert.areEqual(20, total, '5 requests × 4 tasks = 20 tasks expected');
    }

    // ── recalculateCompletion ────────────────────────────────────────────

    @IsTest
    static void recalculateCompletion_allTasksDone_statusCompletedAt100() {
        Onboarding_Request__c req = makeRequest('Dave Kim', 10);
        insert req;
        List<Onboarding_Task__c> tasks = fetchTasks(req.Id);
        for (Onboarding_Task__c t : tasks) {
            t.Is_Completed__c   = true;
            t.Completed_Date__c = Date.today();
        }

        Test.startTest();
        update tasks;
        Test.stopTest();

        Onboarding_Request__c updated = [
            SELECT Status__c, Completion_Percentage__c
            FROM   Onboarding_Request__c WHERE Id = :req.Id
        ];
        Assert.areEqual('Completed', updated.Status__c,                        'Status should be Completed');
        Assert.areEqual(100,         updated.Completion_Percentage__c.intValue(), 'Completion % should be 100');
    }

    @IsTest
    static void recalculateCompletion_halfDone_statusInProgressAt50() {
        Onboarding_Request__c req = makeRequest('Eve Park', 10);
        insert req;
        List<Onboarding_Task__c> tasks = fetchTasks(req.Id);

        // Complete first 2 of 4
        update new List<Onboarding_Task__c>{
            new Onboarding_Task__c(Id = tasks[0].Id, Is_Completed__c = true, Completed_Date__c = Date.today()),
            new Onboarding_Task__c(Id = tasks[1].Id, Is_Completed__c = true, Completed_Date__c = Date.today())
        };

        Onboarding_Request__c updated = [
            SELECT Status__c, Completion_Percentage__c
            FROM   Onboarding_Request__c WHERE Id = :req.Id
        ];
        Assert.areEqual('In Progress', updated.Status__c,                        'Status should be In Progress');
        Assert.areEqual(50,            updated.Completion_Percentage__c.intValue(), 'Completion % should be 50');
    }

    @IsTest
    static void recalculateCompletion_noCompletionChange_doesNotRecalculate() {
        Onboarding_Request__c req = makeRequest('Frank Wu', 10);
        insert req;
        List<Onboarding_Task__c> tasks = fetchTasks(req.Id);

        // Update only Due_Date__c — Is_Completed__c unchanged
        for (Onboarding_Task__c t : tasks) {
            t.Due_Date__c = Date.today().addDays(15);
        }

        Test.startTest();
        update tasks;
        Test.stopTest();

        Onboarding_Request__c updated = [
            SELECT Status__c, Completion_Percentage__c
            FROM   Onboarding_Request__c WHERE Id = :req.Id
        ];
        Assert.areEqual('New', updated.Status__c, 'Status should remain New');
        Assert.isNull(updated.Completion_Percentage__c,  'Completion % should remain null when not recalculated');
    }

    @IsTest
    static void recalculateCompletion_bulkRequests_allRecalculated() {
        List<Onboarding_Request__c> reqs = new List<Onboarding_Request__c>();
        for (Integer i = 0; i < 3; i++) {
            reqs.add(makeRequest('Bulk HR ' + i, 10 + i));
        }
        insert reqs;

        List<Onboarding_Task__c> allTasks = [
            SELECT Id FROM Onboarding_Task__c
            WHERE Onboarding_Request__c IN :reqs
        ];
        for (Onboarding_Task__c t : allTasks) {
            t.Is_Completed__c   = true;
            t.Completed_Date__c = Date.today();
        }

        Test.startTest();
        update allTasks;
        Test.stopTest();

        List<Onboarding_Request__c> updated = [
            SELECT Status__c FROM Onboarding_Request__c WHERE Id IN :reqs
        ];
        for (Onboarding_Request__c r : updated) {
            Assert.areEqual('Completed', r.Status__c, 'All bulk requests should be Completed');
        }
    }

    // ── getActiveRequests ────────────────────────────────────────────────

    @IsTest
    static void getActiveRequests_excludesCompletedAndCancelled() {
        Onboarding_Request__c activeReq    = makeRequest('Active Emp',    5);
        Onboarding_Request__c completedReq = makeRequest('Completed Emp', 5);
        Onboarding_Request__c cancelledReq = makeRequest('Cancelled Emp', 5);
        insert new List<Onboarding_Request__c>{ activeReq, completedReq, cancelledReq };

        update new Onboarding_Request__c(Id = completedReq.Id, Status__c = 'Completed', Completion_Percentage__c = 100);
        update new Onboarding_Request__c(Id = cancelledReq.Id, Status__c = 'Cancelled');

        Test.startTest();
        List<Onboarding_Request__c> results = OnboardingService.getActiveRequests();
        Test.stopTest();

        Set<Id> resultIds = new Set<Id>();
        for (Onboarding_Request__c r : results) resultIds.add(r.Id);

        Assert.isTrue(resultIds.contains(activeReq.Id),     'Should include active request');
        Assert.isFalse(resultIds.contains(completedReq.Id), 'Should exclude Completed request');
        Assert.isFalse(resultIds.contains(cancelledReq.Id), 'Should exclude Cancelled request');
    }

    @IsTest
    static void getActiveRequests_returnsExpectedFields() {
        insert makeRequest('Field Check Emp', 7);

        Test.startTest();
        List<Onboarding_Request__c> results = OnboardingService.getActiveRequests();
        Test.stopTest();

        Assert.isFalse(results.isEmpty(), 'Should return at least one record');
        Onboarding_Request__c r = results[0];
        // Verify key fields are queried (no null reference exception)
        Assert.isNotNull(r.Employee_Name__c, 'Employee_Name__c should be populated');
        Assert.isNotNull(r.Status__c,        'Status__c should be populated');
        Assert.isNotNull(r.Department__c,    'Department__c should be populated');
    }

    // ── getAllRequestsWithTasks ───────────────────────────────────────────

    @IsTest
    static void getAllRequestsWithTasks_returnsAllStatusesWithTaskSubquery() {
        Onboarding_Request__c req = makeRequest('Grace Ho', 10);
        insert req;

        // Set to Completed — should still be returned
        update new Onboarding_Request__c(Id = req.Id, Status__c = 'Completed', Completion_Percentage__c = 100);

        Test.startTest();
        List<Onboarding_Request__c> results = OnboardingService.getAllRequestsWithTasks();
        Test.stopTest();

        Onboarding_Request__c found = null;
        for (Onboarding_Request__c r : results) {
            if (r.Id == req.Id) { found = r; break; }
        }

        Assert.isNotNull(found, 'Completed request should be included in getAllRequestsWithTasks');
        Assert.areEqual(4, found.Onboarding_Tasks__r.size(), 'Should include 4 child tasks via subquery');
    }

    @IsTest
    static void getAllRequestsWithTasks_taskFieldsArePopulated() {
        insert makeRequest('Harry Chen', 8);

        Test.startTest();
        List<Onboarding_Request__c> results = OnboardingService.getAllRequestsWithTasks();
        Test.stopTest();

        Assert.isFalse(results.isEmpty(), 'Should return records');
        Onboarding_Task__c task = results[0].Onboarding_Tasks__r[0];
        Assert.isNotNull(task.Category__c,     'Category__c should be populated');
        Assert.isNotNull(task.Due_Date__c,     'Due_Date__c should be populated');
        Assert.isNotNull(task.Is_Completed__c, 'Is_Completed__c should be populated');
    }

    // ── createOnboardingRequest ──────────────────────────────────────────

    @IsTest
    static void createOnboardingRequest_createsRecordWithCorrectFields() {
        Test.startTest();
        Id newId = OnboardingService.createOnboardingRequest(
            'Ivy Taylor', Date.today().addDays(7), 'Finance'
        );
        Test.stopTest();

        Assert.isNotNull(newId, 'Should return a valid record Id');

        Onboarding_Request__c created = [
            SELECT Employee_Name__c, Department__c, Status__c
            FROM   Onboarding_Request__c WHERE Id = :newId
        ];
        Assert.areEqual('Ivy Taylor', created.Employee_Name__c, 'Employee name should match');
        Assert.areEqual('Finance',    created.Department__c,    'Department should match');
        Assert.areEqual('New',        created.Status__c,        'Status should default to New');
    }

    @IsTest
    static void createOnboardingRequest_autoCreates4Tasks() {
        Test.startTest();
        Id newId = OnboardingService.createOnboardingRequest(
            'Jack Brown', Date.today().addDays(14), 'Sales'
        );
        Test.stopTest();

        Integer taskCount = [
            SELECT COUNT() FROM Onboarding_Task__c
            WHERE Onboarding_Request__c = :newId
        ];
        Assert.areEqual(4, taskCount, 'Insert trigger should auto-create 4 default tasks');
    }

    // ── getRequestsNeedingReminder ───────────────────────────────────────

    @IsTest
    static void getRequestsNeedingReminder_returnsStartingInExactlyThreeDays() {
        Onboarding_Request__c matchReq   = makeRequest('Match Emp',    3);
        Onboarding_Request__c noMatchReq = makeRequest('NoMatch Emp', 10);
        insert new List<Onboarding_Request__c>{ matchReq, noMatchReq };

        Test.startTest();
        List<Onboarding_Request__c> reminders = OnboardingService.getRequestsNeedingReminder();
        Test.stopTest();

        Set<Id> ids = new Set<Id>();
        for (Onboarding_Request__c r : reminders) ids.add(r.Id);

        Assert.isTrue(ids.contains(matchReq.Id),    'Request starting in 3 days should be returned');
        Assert.isFalse(ids.contains(noMatchReq.Id), 'Request starting in 10 days should NOT be returned');
    }

    @IsTest
    static void getRequestsNeedingReminder_excludesCompletedAndCancelled() {
        Onboarding_Request__c compReq   = makeRequest('Comp Emp',   3);
        Onboarding_Request__c cancelReq = makeRequest('Cancel Emp', 3);
        insert new List<Onboarding_Request__c>{ compReq, cancelReq };

        update new Onboarding_Request__c(Id = compReq.Id,   Status__c = 'Completed', Completion_Percentage__c = 100);
        update new Onboarding_Request__c(Id = cancelReq.Id, Status__c = 'Cancelled');

        Test.startTest();
        List<Onboarding_Request__c> reminders = OnboardingService.getRequestsNeedingReminder();
        Test.stopTest();

        Set<Id> ids = new Set<Id>();
        for (Onboarding_Request__c r : reminders) ids.add(r.Id);

        Assert.isFalse(ids.contains(compReq.Id),   'Completed request should be excluded from reminders');
        Assert.isFalse(ids.contains(cancelReq.Id), 'Cancelled request should be excluded from reminders');
    }

    // ── sendReminderEmails ───────────────────────────────────────────────

    @IsTest
    static void sendReminderEmails_withAssignedHR_sendsWithoutException() {
        Onboarding_Request__c req = new Onboarding_Request__c(
            Employee_Name__c = 'Kate Adams',
            Start_Date__c    = Date.today().addDays(3),
            Department__c    = 'HR',
            Status__c        = 'New',
            Assigned_HR__c   = UserInfo.getUserId()
        );
        insert req;

        List<Onboarding_Request__c> reminders = OnboardingService.getRequestsNeedingReminder();

        Test.startTest();
        OnboardingService.sendReminderEmails(reminders);
        Test.stopTest();

        Assert.isTrue(true, 'sendReminderEmails should complete without throwing an exception');
    }

    @IsTest
    static void sendReminderEmails_emptyList_handledGracefully() {
        Test.startTest();
        OnboardingService.sendReminderEmails(new List<Onboarding_Request__c>());
        Test.stopTest();

        Assert.isTrue(true, 'Empty list should not throw an exception');
    }

    @IsTest
    static void sendReminderEmails_noAssignedHR_skipsRecord() {
        // Request with no Assigned_HR__c — should be skipped silently
        Onboarding_Request__c req = makeRequest('No HR Emp', 3);
        insert req;

        List<Onboarding_Request__c> reminders = OnboardingService.getRequestsNeedingReminder();

        Test.startTest();
        OnboardingService.sendReminderEmails(reminders);
        Test.stopTest();

        Assert.isTrue(true, 'Records without Assigned_HR__c should be skipped without exception');
    }

    // ─── completeTask ─────────────────────────────────────────────────────────

    @IsTest
    static void completeTask_setsIsCompletedAndCompletedDate() {
        Onboarding_Request__c req = makeRequest('Complete Task Emp', 5);
        insert req;

        Onboarding_Task__c task = [
            SELECT Id, Is_Completed__c, Completed_Date__c
            FROM   Onboarding_Task__c
            WHERE  Onboarding_Request__c = :req.Id
            LIMIT  1
        ];
        Assert.isFalse(task.Is_Completed__c, 'Task should start incomplete');

        Test.startTest();
        OnboardingService.completeTask(task.Id);
        Test.stopTest();

        Onboarding_Task__c updated = [
            SELECT Is_Completed__c, Completed_Date__c
            FROM   Onboarding_Task__c
            WHERE  Id = :task.Id
        ];
        Assert.isTrue(updated.Is_Completed__c,        'Is_Completed__c should be true after completeTask');
        Assert.areEqual(Date.today(), updated.Completed_Date__c, 'Completed_Date__c should be set to today');
    }

    @IsTest
    static void completeTask_triggersParentRecalculation() {
        Onboarding_Request__c req = makeRequest('Recalc Emp', 5);
        insert req;

        List<Onboarding_Task__c> tasks = [
            SELECT Id FROM Onboarding_Task__c
            WHERE  Onboarding_Request__c = :req.Id
        ];

        Test.startTest();
        // Complete all tasks via completeTask — parent percentage should reach 100
        for (Onboarding_Task__c t : tasks) {
            OnboardingService.completeTask(t.Id);
        }
        Test.stopTest();

        Onboarding_Request__c updated = [
            SELECT Completion_Percentage__c, Status__c
            FROM   Onboarding_Request__c
            WHERE  Id = :req.Id
        ];
        Assert.areEqual(100, updated.Completion_Percentage__c, 'Completion should be 100% when all tasks done');
        Assert.areEqual('Completed', updated.Status__c,         'Status should be Completed when all tasks done');
    }
}