trigger UserTrigger on User (after insert) {
    UserTriggerHelper.handleAfterInsert(Trigger.new);
}