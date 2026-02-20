/**
 * @description Trigger for Onboarding_Task__c.
 *              Follows the "one trigger per object" best practice.
 *              All logic is handled in OnboardingTaskTriggerHandler.
 */
trigger OnboardingTaskTrigger on Onboarding_Task__c (after update) {
    OnboardingTaskTriggerHandler.handle(Trigger.new, Trigger.oldMap, Trigger.operationType);
}