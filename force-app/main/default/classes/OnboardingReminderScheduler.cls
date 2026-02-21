/**
 * @description Scheduled Apex class that runs daily at 8 AM.
 *              Enqueues OnboardingReminderBatch to find Onboarding Requests
 *              starting in 3 days with incomplete tasks and send reminder emails.
 *
 *              Using a batch class (instead of calling the service directly) ensures
 *              the email governor limit is not breached when large numbers of requests
 *              need reminders — each batch chunk runs in its own transaction.
 *
 * Schedule via Anonymous Apex:
 *   OnboardingReminderScheduler job = new OnboardingReminderScheduler();
 *   System.schedule('Daily Onboarding Reminders', '0 0 8 * * ?', job);
 */
public with sharing class OnboardingReminderScheduler implements Schedulable {

    /**
     * @description Called by the Salesforce scheduler. Enqueues OnboardingReminderBatch
     *              with a chunk size of 50 to process reminder emails safely at scale.
     * @param ctx SchedulableContext provided by the platform
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new OnboardingReminderBatch(), 50);
    }
}