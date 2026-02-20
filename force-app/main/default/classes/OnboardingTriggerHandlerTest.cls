/**
 * @description Tests for OnboardingRequestTriggerHandler and
 *              OnboardingTaskTriggerHandler, exercised through DML operations.
 */
@IsTest
private class OnboardingTriggerHandlerTest {

    // ── Helpers ──────────────────────────────────────────────────────────

    private static Onboarding_Request__c insertRequest(Integer daysFromNow) {
        Onboarding_Request__c req = new Onboarding_Request__c(
            Employee_Name__c = 'Trigger Test Emp',
            Start_Date__c    = Date.today().addDays(daysFromNow),
            Department__c    = 'IT',
            Status__c        = 'New',
            Assigned_HR__c   = UserInfo.getUserId()
        );
        insert req;
        return req;
    }

    private static List<Onboarding_Task__c> getTasks(Id requestId) {
        return [
            SELECT Id, Is_Completed__c FROM Onboarding_Task__c
            WHERE Onboarding_Request__c = :requestId
        ];
    }

    // ── OnboardingRequestTriggerHandler — AFTER INSERT ────────────────────

    @IsTest
    static void requestTrigger_afterInsert_creates4Tasks() {
        Test.startTest();
        Onboarding_Request__c req = insertRequest(10);
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM Onboarding_Task__c
            WHERE Onboarding_Request__c = :req.Id
        ];
        Assert.areEqual(4, count, 'AFTER INSERT should trigger creation of exactly 4 tasks');
    }

    @IsTest
    static void requestTrigger_afterInsert_tasksDefaultToIncomplete() {
        Onboarding_Request__c req = insertRequest(10);

        for (Onboarding_Task__c t : getTasks(req.Id)) {
            Assert.areEqual(false, t.Is_Completed__c, 'Newly created tasks should default to incomplete');
        }
    }

    @IsTest
    static void requestTrigger_afterInsert_bulkHandledCorrectly() {
        List<Onboarding_Request__c> reqs = new List<Onboarding_Request__c>();
        for (Integer i = 0; i < 10; i++) {
            reqs.add(new Onboarding_Request__c(
                Employee_Name__c = 'Bulk Test ' + i,
                Start_Date__c    = Date.today().addDays(10 + i),
                Department__c    = 'HR',
                Status__c        = 'New',
                Assigned_HR__c   = UserInfo.getUserId()
            ));
        }

        Test.startTest();
        insert reqs;
        Test.stopTest();

        Integer total = [
            SELECT COUNT() FROM Onboarding_Task__c
            WHERE Onboarding_Request__c IN :reqs
        ];
        Assert.areEqual(40, total, 'Bulk insert: 10 requests × 4 tasks = 40 tasks');
    }

    // ── OnboardingRequestTriggerHandler — AFTER UPDATE ───────────────────

    @IsTest
    static void requestTrigger_afterUpdate_doesNotCreateAdditionalTasks() {
        Onboarding_Request__c req = insertRequest(10);
        Integer countBefore = [
            SELECT COUNT() FROM Onboarding_Task__c
            WHERE Onboarding_Request__c = :req.Id
        ];

        Test.startTest();
        update new Onboarding_Request__c(Id = req.Id, Status__c = 'In Progress');
        Test.stopTest();

        Integer countAfter = [
            SELECT COUNT() FROM Onboarding_Task__c
            WHERE Onboarding_Request__c = :req.Id
        ];
        Assert.areEqual(countBefore, countAfter, 'AFTER UPDATE should NOT create extra tasks');
    }

    // ── OnboardingTaskTriggerHandler — AFTER UPDATE ───────────────────────

    @IsTest
    static void taskTrigger_allTasksCompleted_parentStatusCompleted() {
        Onboarding_Request__c req = insertRequest(10);
        List<Onboarding_Task__c> tasks = getTasks(req.Id);

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
        Assert.areEqual('Completed', updated.Status__c,                        'Parent status should be Completed');
        Assert.areEqual(100,         updated.Completion_Percentage__c.intValue(), 'Completion % should be 100');
    }

    @IsTest
    static void taskTrigger_oneTaskCompleted_parentStatusInProgress() {
        Onboarding_Request__c req = insertRequest(10);
        List<Onboarding_Task__c> tasks = getTasks(req.Id);

        Test.startTest();
        update new Onboarding_Task__c(
            Id              = tasks[0].Id,
            Is_Completed__c = true,
            Completed_Date__c = Date.today()
        );
        Test.stopTest();

        Onboarding_Request__c updated = [
            SELECT Status__c, Completion_Percentage__c
            FROM   Onboarding_Request__c WHERE Id = :req.Id
        ];
        Assert.areEqual('In Progress', updated.Status__c, 'Parent status should be In Progress');
        Assert.isTrue(
            updated.Completion_Percentage__c > 0 && updated.Completion_Percentage__c < 100,
            'Completion % should be between 0 and 100'
        );
    }

    @IsTest
    static void taskTrigger_noCompletionFieldChange_parentUnchanged() {
        Onboarding_Request__c req = insertRequest(10);
        List<Onboarding_Task__c> tasks = getTasks(req.Id);

        // Update Due_Date__c only — Is_Completed__c NOT changed
        for (Onboarding_Task__c t : tasks) {
            t.Due_Date__c = Date.today().addDays(20);
        }

        Test.startTest();
        update tasks;
        Test.stopTest();

        Onboarding_Request__c updated = [
            SELECT Status__c, Completion_Percentage__c
            FROM   Onboarding_Request__c WHERE Id = :req.Id
        ];
        Assert.areEqual('New', updated.Status__c, 'Status should stay New when Is_Completed__c unchanged');
        Assert.isNull(updated.Completion_Percentage__c, 'Completion % should remain null');
    }

    @IsTest
    static void taskTrigger_mixedUpdates_onlyChangedTasksPassedToService() {
        Onboarding_Request__c req = insertRequest(10);
        List<Onboarding_Task__c> tasks = getTasks(req.Id);

        // Mark first task complete, update due date on second — both in one DML
        List<Onboarding_Task__c> toUpdate = new List<Onboarding_Task__c>{
            new Onboarding_Task__c(
                Id              = tasks[0].Id,
                Is_Completed__c = true,
                Completed_Date__c = Date.today()
            ),
            new Onboarding_Task__c(
                Id            = tasks[1].Id,
                Due_Date__c   = Date.today().addDays(20)
            )
        };

        Test.startTest();
        update toUpdate;
        Test.stopTest();

        // recalculation should fire (1 task changed), resulting in 1/4 = 25%
        Onboarding_Request__c updated = [
            SELECT Status__c, Completion_Percentage__c
            FROM   Onboarding_Request__c WHERE Id = :req.Id
        ];
        Assert.areEqual('In Progress', updated.Status__c, 'Status should be In Progress');
        Assert.areEqual(25, updated.Completion_Percentage__c.intValue(), '1 of 4 tasks = 25%');
    }

    @IsTest
    static void taskTrigger_bulkRequests_allParentsRecalculated() {
        List<Onboarding_Request__c> reqs = new List<Onboarding_Request__c>();
        for (Integer i = 0; i < 5; i++) {
            reqs.add(new Onboarding_Request__c(
                Employee_Name__c = 'Bulk Task Emp ' + i,
                Start_Date__c    = Date.today().addDays(10 + i),
                Department__c    = 'Sales',
                Status__c        = 'New',
                Assigned_HR__c   = UserInfo.getUserId()
            ));
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
            Assert.areEqual('Completed', r.Status__c, 'Bulk: every parent should reach Completed');
        }
    }
}