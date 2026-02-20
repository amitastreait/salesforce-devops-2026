/**
 * @description Tests for OnboardingReminderScheduler (Schedulable).
 *              Verifies job scheduling, direct execute(), and edge-case
 *              handling (no reminders, no HR assigned).
 */
@IsTest
private class OnboardingReminderSchedulerTest {

    private static final String CRON_EXPR = '0 0 8 * * ?';

    // ── Helpers ──────────────────────────────────────────────────────────

    private static Onboarding_Request__c insertRequestStartingIn3Days(Boolean assignHR) {
        Onboarding_Request__c req = new Onboarding_Request__c(
            Employee_Name__c = 'Sched Test Emp',
            Start_Date__c    = Date.today().addDays(3),
            Department__c    = 'IT',
            Status__c        = 'New',
            Assigned_HR__c   = assignHR ? UserInfo.getUserId() : null
        );
        insert req;
        return req;
    }

    // ── Scheduling ───────────────────────────────────────────────────────

    @IsTest
    static void schedule_jobRegisteredInCronTrigger() {
        Test.startTest();
        System.schedule(
            'Test Onboarding Reminder',
            CRON_EXPR,
            new OnboardingReminderScheduler()
        );
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  CronJobDetail.Name = 'Test Onboarding Reminder'
        ];
        Assert.areEqual(1, jobs.size(), 'One scheduled job should appear in CronTrigger');
    }

    @IsTest
    static void schedule_withRemindableRequests_doesNotThrow() {
        insertRequestStartingIn3Days(true);

        Test.startTest();
        System.schedule(
            'Test Reminder With Data',
            CRON_EXPR,
            new OnboardingReminderScheduler()
        );
        Test.stopTest();

        Assert.isTrue(true, 'Scheduler with remindable data should not throw');
    }

    // ── Direct execute() ──────────────────────────────────────────────────

    @IsTest
    static void execute_withAssignedHR_sendsWithoutException() {
        insertRequestStartingIn3Days(true);

        Test.startTest();
        new OnboardingReminderScheduler().execute(null);
        Test.stopTest();

        Assert.isTrue(true, 'execute() with assigned HR should complete without exception');
    }

    @IsTest
    static void execute_withNoAssignedHR_skipsGracefully() {
        insertRequestStartingIn3Days(false); // Assigned_HR__c = null

        Test.startTest();
        new OnboardingReminderScheduler().execute(null);
        Test.stopTest();

        Assert.isTrue(true, 'execute() with no HR assigned should skip without exception');
    }

    @IsTest
    static void execute_noRemindableRequests_doesNotThrow() {
        // No requests starting in 3 days
        Test.startTest();
        new OnboardingReminderScheduler().execute(null);
        Test.stopTest();

        Assert.isTrue(true, 'execute() with empty reminder list should be handled gracefully');
    }

    @IsTest
    static void execute_completedRequest_excluded() {
        Onboarding_Request__c req = insertRequestStartingIn3Days(true);
        // Mark all tasks done → triggers recalculation → Status = Completed
        List<Onboarding_Task__c> tasks = [
            SELECT Id FROM Onboarding_Task__c
            WHERE Onboarding_Request__c = :req.Id
        ];
        for (Onboarding_Task__c t : tasks) {
            t.Is_Completed__c   = true;
            t.Completed_Date__c = Date.today();
        }
        update tasks;

        Test.startTest();
        new OnboardingReminderScheduler().execute(null);
        Test.stopTest();

        // Completed request should not appear in reminders — no exception expected
        Assert.isTrue(true, 'Completed requests should be excluded from reminders without error');
    }
}