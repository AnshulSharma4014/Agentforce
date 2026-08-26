public without sharing class UserTriggerHelper {

    public static void handleAfterInsert(List<User> newUsers) {
        if(!newUsers.isEmpty()) {
            Id jobId = System.enqueueJob(new PermissionSetAssignmentQueuable(newUsers));
        }
    }
}