/****** Object:  StoredProcedure [auth].[GetUserToken]  -- OPTIMIZED ******/
-- Combined the two INSERTs into one lookup instead of writing to a temp table twice.

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

    -- Find the person by email or token, in one go
    WITH MatchedPerson AS (
        SELECT p.Id AS PersonId
        FROM acct.Person p
        WHERE (@emailAddress IS NOT NULL AND p.EmailAddress = @emailAddress)
           OR (@token IS NOT NULL AND EXISTS (
                    SELECT 1
                    FROM auth.UserToken ut2
                    WHERE ut2.PersonId = p.Id
                      AND ut2.Token = @token
               ))
    )
    SELECT
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
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END
GO
