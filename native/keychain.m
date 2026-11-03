#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <string.h>

// Narrow scope, no access-group override and no search for unrelated credentials.
static NSMutableDictionary *MicaKeyQuery(void) {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"local.dan.desktop-companion.openai",
        (__bridge id)kSecAttrAccount:@"default",
        (__bridge id)kSecUseDataProtectionKeychain:@NO} mutableCopy];
}
static NSDictionary *MicaKeyAttributes(NSData *data) {
    return @{(__bridge id)kSecValueData:data};
}
// The file-based default Keychain works for a local ad-hoc signed Mac app.
// It remains encrypted and uses the system default ACL (trust this caller).
// Do not add access-group entitlements or broaden the trusted-app list.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus MicaDefaultKeychain(SecKeychainRef *keychain) {
    return SecKeychainCopyDefault(keychain);
}
#pragma clang diagnostic pop
static void MicaScopeQuery(NSMutableDictionary *query, SecKeychainRef keychain) {
    query[(__bridge id)kSecMatchSearchList] = @[(__bridge id)keychain];
}
int32_t mica_keychain_put(const char *key) {
    @autoreleasepool {
        if (!key) return errSecParam;
        NSData *data = [NSData dataWithBytes:key length:strlen(key)];
        SecKeychainRef keychain = NULL;
        OSStatus opened = MicaDefaultKeychain(&keychain);
        if (opened != errSecSuccess) return opened;
        NSMutableDictionary *query = MicaKeyQuery();
        NSDictionary *attributes = MicaKeyAttributes(data);
        MicaScopeQuery(query, keychain);
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
        if (status == errSecItemNotFound) {
            [query removeObjectForKey:(__bridge id)kSecMatchSearchList];
            query[(__bridge id)kSecUseKeychain] = (__bridge id)keychain;
            [query addEntriesFromDictionary:attributes];
            query[(__bridge id)kSecAttrLabel] = @"Mica OpenAI API key";
            status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        }
        CFRelease(keychain);
        return status;
    }
}
int32_t mica_keychain_get(char **value) {
    @autoreleasepool {
        if (!value) return errSecParam;
        *value = NULL;
        SecKeychainRef keychain = NULL;
        OSStatus opened = MicaDefaultKeychain(&keychain);
        if (opened != errSecSuccess) return opened;
        NSMutableDictionary *query = MicaKeyQuery();
        MicaScopeQuery(query, keychain);
        query[(__bridge id)kSecReturnData] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        CFRelease(keychain);
        if (status != errSecSuccess) return status;
        NSData *data = CFBridgingRelease(result);
        if (![data isKindOfClass:NSData.class] || data.length == 0 || data.length > 512 || memchr(data.bytes, 0, data.length)) return errSecDecode;
        char *copy = calloc(data.length + 1, 1);
        if (!copy) return errSecAllocate;
        memcpy(copy, data.bytes, data.length);
        *value = copy;
        return errSecSuccess;
    }
}
int32_t mica_keychain_delete(void) {
    @autoreleasepool {
        SecKeychainRef keychain = NULL;OSStatus status=MicaDefaultKeychain(&keychain);
        if(status!=errSecSuccess) return status;
        NSMutableDictionary *query=MicaKeyQuery();MicaScopeQuery(query,keychain);
        status=SecItemDelete((__bridge CFDictionaryRef)query);CFRelease(keychain);return status;
    }
}
void mica_secret_free(char *value) {
    if (value) {size_t length = strlen(value);volatile unsigned char *bytes = (volatile unsigned char *)value;while (length--) *bytes++ = 0;free(value);}
}
int mica_keychain_policy_tests(void) {
    @autoreleasepool {
        NSDictionary *query = MicaKeyQuery();
        NSDictionary *attributes = MicaKeyAttributes([NSData data]);
        BOOL checks[] = {
            [query[(__bridge id)kSecAttrService] isEqual:@"local.dan.desktop-companion.openai"] && [query[(__bridge id)kSecAttrAccount] isEqual:@"default"],
            [query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword],
            ![query[(__bridge id)kSecUseDataProtectionKeychain] boolValue],
            query[(__bridge id)kSecAttrSynchronizable] == nil && query[(__bridge id)kSecAttrAccessGroup] == nil,
            query[(__bridge id)kSecUseAuthenticationContext] == nil,
            attributes[(__bridge id)kSecAttrAccess] == nil && attributes[(__bridge id)kSecAttrAccessible] == nil
        };
        int failures = 0;
        for (size_t i = 0; i < sizeof(checks)/sizeof(checks[0]); i++) if (!checks[i]) failures++;
        printf("Keychain query policy: 6 checks, %d failure(s). No Keychain operation performed.\n", failures);
        return failures ? 1 : 0;
    }
}
