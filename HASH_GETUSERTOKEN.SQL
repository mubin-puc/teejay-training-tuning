/****** Object:  StoredProcedure [auth].[GetUserToken]  -- OPTIMIZED VERSION ******/
-- All optimizations included:
-- 1. Combined the two INSERTs into one lookup.
-- 2. TOP 1 + ORDER BY so we always get exactly one row (needed since the
--    output is a single JSON object, not an array).
-- 3. Token search now uses TokenHash first (fast, indexable) then double
--    -checks the real Token (since hash matches can rarely collide).
--    Token stays NVARCHAR(MAX) as-is -- no data type change needed.
--
-- IMPORTANT: Run the index script at the bottom of this file FIRST,
-- before deploying this SP -- it needs TokenHash to already exist.

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [auth].[GetUserToken](
    @emailAddress NVARCHAR(255) = NULL,
    @token NVARCHAR(MAX) = NULL,
    @userTokenType INT
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Find the person by email or token, in one go (was two separate INSERTs before)
    ;WITH MatchedPerson AS (
        SELECT p.Id AS PersonId
        FROM acct.Person p
        WHERE (@emailAddress IS NOT NULL AND p.EmailAddress = @emailAddress)
           OR (@token IS NOT NULL AND EXISTS (
                    SELECT 1
                    FROM auth.UserToken ut2
                    -- Check the hash first (fast, uses the index), then confirm
                    -- the real token to rule out the rare case of two tokens
                    -- sharing the same hash.
                    WHERE ut2.PersonId = p.Id
                      AND ut2.TokenHash = CHECKSUM(@token)
                      AND ut2.Token = @token
               ))
    )
    -- TOP 1 + ORDER BY: guarantees exactly one row, since the JSON output
    -- below (WITHOUT_ARRAY_WRAPPER) only works for a single row. Picks the
    -- newest valid token if a person somehow has more than one.
    SELECT TOP 1
        ut.Id,
        ut.Token,
        ut.PersonId,
        ut.EffectiveEndDate,
        ut.Status,
        p.EmailAddress [Person.EmailAddress],
        ua.Id [Person.UserAuthentication.Id],
        ua.Password [Person.UserAuthentication.Password],
        ua.Salt [Person.UserAuthentication.Salt]
    FROM MatchedPerson mp
        JOIN acct.Person p ON mp.PersonId = p.Id
        JOIN auth.UserToken ut ON ut.PersonId = p.Id
        LEFT JOIN auth.UserAuthentication ua ON p.Id = ua.PersonId
    WHERE ut.Type = @userTokenType
      AND ut.Status = 0 /* Valid */
    ORDER BY ut.EffectiveEndDate DESC
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END
GO


/* ============================================================
   RUN THIS FIRST, BEFORE DEPLOYING THE SP ABOVE.
   Token stays NVARCHAR(MAX) (no data type change, per company rule).
   This adds a small "fingerprint" column we CAN index, and indexes it.
   ============================================================ */

-- Adds a fast-searchable fingerprint of Token (auto-updates itself, no app changes needed)
ALTER TABLE auth.UserToken ADD TokenHash AS CHECKSUM(Token) PERSISTED;

-- Indexes that fingerprint, so lookups by token become fast (Seek instead of Scan)
CREATE NONCLUSTERED INDEX IX_UserToken_TokenHash
    ON auth.UserToken (TokenHash)
    INCLUDE (PersonId);

-- Also speeds up the email lookup
CREATE NONCLUSTERED INDEX IX_Person_EmailAddress
    ON acct.Person (EmailAddress)
    INCLUDE (Id);

-- Also speeds up the final join/filter on UserToken
CREATE NONCLUSTERED INDEX IX_UserToken_PersonId_Type_Status
    ON auth.UserToken (PersonId, Type, Status)
    INCLUDE (Token, EffectiveEndDate);
