public with sharing class TestApexAvailability {
    
    public class Request {
        @InvocableVariable
        public String input;
    }

    public class Response {
        @InvocableVariable
        public String output;
    }

    @InvocableMethod(label='Test Apex Availability')
    public static List<Response> execute(List<Request> requests) {
        Response r = new Response();
        r.output = 'APEX WAS INVOKED';
        return new List<Response>{ r };
    }
}