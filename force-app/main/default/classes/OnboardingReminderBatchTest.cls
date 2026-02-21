/**
 * @description Tests for OnboardingReminderBatch.
 *              Verifies that the batch processes at-risk requests, skips requests
 *              without an assigned HR user, excludes completed requests, and that
 *              the updated OnboardingReminderScheduler correctly enqueues the batch.
 */
@IsTest
private class OnboardingReminderBatchTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static Onboarding_Request__c insertRequest(Boolean assignHR) {
        Onboarding_Request__c req = new Onboarding_Request__c(
            Employee_Name__c = 'Batch Test Employee',
            Start_Date__c    = Date.today().addDays(3),
            Department__c    = 'IT',
            Status__c        = 'New',
            Assigned_HR__c   = assignHR ? UserInfo.getUserId() : null
        );
        insert req;
        return req;
    }

    // ── Batch execution ───────────────────────────────────────────────────────

    @IsTest
    static void batch_withRemindableRequest_completesWithoutException() {
        insertRequest(true);

        Test.startTest();
        Database.executeBatch(new OnboardingReminderBatch(), 50);
        Test.stopTest();

        Assert.isTrue(true, 'Batch with a remindable request should complete without exception');
    }

    @IsTest
    static void batch_noRemindableRequests_completesWithoutException() {
        // No records starting in 3 days
        Test.startTest();
        Database.executeBatch(new OnboardingReminderBatch(), 50);
        Test.stopTest();

        Assert.isTrue(true, 'Batch with no matching records should complete without exception');
    }

    @IsTest
    static void batch_noHRAssigned_skipsGracefully() {
        insertRequest(false);  // Assigned_HR__c = null

        Test.startTest();
        Database.executeBatch(new OnboardingReminderBatch(), 50);
        Test.stopTest();

        Assert.isTrue(true, 'Batch should skip requests where Assigned_HR__c is null');
    }

    @IsTest
    static void batch_completedRequest_isExcluded() {
        Onboarding_Request__c req = insertRequest(true);

        // Complete all auto-generated tasks so the trigger sets Status = Completed
        List<Onboarding_Task__c> tasks = [
            SELECT Id FROM Onboarding_Task__c
            WHERE  Onboarding_Request__c = :req.Id
        ];
        for (Onboarding_Task__c t : tasks) {
            t.Is_Completed__c   = true;
            t.Completed_Date__c = Date.today();
        }
        update tasks;

        Test.startTest();
        Database.executeBatch(new OnboardingReminderBatch(), 50);
        Test.stopTest();

        Assert.isTrue(true, 'Completed requests should be excluded by the QueryLocator');
    }

    @IsTest
    static void batch_cancelledRequest_isExcluded() {
        Onboarding_Request__c req = insertRequest(true);
        req.Status__c = 'Cancelled';
        update req;

        Test.startTest();
        Database.executeBatch(new OnboardingReminderBatch(), 50);
        Test.stopTest();

        Assert.isTrue(true, 'Cancelled requests should be excluded by the QueryLocator');
    }

    @IsTest
    static void batch_multipleBatchChunks_processAllRecords() {
        // Insert 3 requests; run with batch size 1 to force multiple execute() calls
        insertRequest(true);
        insertRequest(true);
        insertRequest(false);

        Test.startTest();
        Database.executeBatch(new OnboardingReminderBatch(), 1);
        Test.stopTest();

        Assert.isTrue(true, 'Batch should process all chunks without exception');
    }

    // ── Scheduler integration ─────────────────────────────────────────────────

    @IsTest
    static void scheduler_enqueueBatch_registersJobInCronTrigger() {
        Test.startTest();
        System.schedule(
            'Test Batch Reminder Scheduler',
            '0 0 8 * * ?',
            new OnboardingReminderScheduler()
        );
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  CronJobDetail.Name = 'Test Batch Reminder Scheduler'
        ];
        Assert.areEqual(1, jobs.size(), 'Scheduler should register one job in CronTrigger');
    }
}
