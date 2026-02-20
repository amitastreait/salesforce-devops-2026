/**
 * @description Trigger for Onboarding_Request__c.
 *              Follows the "one trigger per object" best practice.
 *              All logic is handled in OnboardingRequestTriggerHandler.
 */
trigger OnboardingRequestTrigger on Onboarding_Request__c (after insert, after update) {
    OnboardingRequestTriggerHandler.handle(Trigger.new, Trigger.oldMap, Trigger.operationType);
}