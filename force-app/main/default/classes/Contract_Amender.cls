public with sharing class Contract_Amender {

    public QuoteModel load(String contractId, String context) {
 
        String quoteJSON = SBQQ.ServiceRouter.load('SBQQ.ContractManipulationAPI.ContractAmender', contractId, context);
        return (QuoteModel) JSON.deserialize(quoteJSON, QuoteModel.class);
    }

    // Create an amendment context
    public with sharing class AmendmentContext {
        public Boolean returnOnlyQuoteId;
    }
    
    public with sharing class QuoteModel {
        public String Id;
        public AttributesObj attributes;
    }

    public with sharing class AttributesObj {
        public String type;
        public String url;
    }
    
}

