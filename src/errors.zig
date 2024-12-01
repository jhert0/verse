pub const ServerError = error{
    OutOfMemory,
    NoSpaceLeft,
    NotImplemented,
    Unknown,
};

pub const ClientError = error{
    Abusive,
    BadData,
    DataMissing,
    InvalidURI,
    Unauthenticated,
    Unrouteable,
    NetworkCrash,
};

pub const NetworkError = error{
    NetworkCrash,
};

pub const Error = ServerError || ClientError || NetworkError;
