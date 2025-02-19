// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Shared
import BraveShared
import BraveCore
import BraveVPN
import os.log

public class BraveSkusManager {
  private let sku: SkusSkusService
  
  public init?(isPrivateMode: Bool) {
    guard let skusService = Skus.SkusServiceFactory.get(privateMode: isPrivateMode) else {
      assert(isPrivateMode, "SkusServiceFactory failed to intialize in regular mode, something is wrong.")
      return nil
    }
    
    self.sku = skusService
  }
  
  public static func refreshSKUCredential(isPrivate: Bool) {
    guard let _ = Preferences.VPN.skusCredential.value,
          let domain = Preferences.VPN.skusCredentialDomain.value,
          let expirationDate = Preferences.VPN.expirationDate.value else {
      Logger.module.debug("No skus credentials stored in the app.")
      return
    }
    
    guard expirationDate < Date() else {
      Logger.module.debug("Existing sku credential has not expired yet, no need to refresh it.")
      return
    }
    
    guard let manager = BraveSkusManager(isPrivateMode: isPrivate) else {
      return
    }
    
    Logger.module.debug("Refreshing sku credential. Clearing old credential from persistence.")
    
    BraveVPN.clearSkusCredentials()
    
    manager.credentialSummary(for: domain) { completion in
      Logger.module.debug("credentialSummary response")
    }
  }
  
  // MARK: - Handling SKU methods.
  
  func refreshOrder(for orderId: String, domain: String, resultJSON: @escaping (Any?) -> Void) {
    sku.refreshOrder(domain, orderId: orderId) { completion in
      do {
        guard let data = completion.data(using: .utf8) else { return }
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        Logger.module.debug("refreshOrder json parsed successfully")
        resultJSON(json)
      } catch {
        resultJSON(nil)
        Logger.module.error("refrshOrder: Failed to decode json: \(error.localizedDescription)")
      }
    }
  }
  
  func fetchOrderCredentials(for orderId: String, domain: String, resultCredential: @escaping (String) -> Void) {
    sku.fetchOrderCredentials(domain, orderId: orderId) { completion in
      Logger.module.debug("skus fetchOrderCredentials")
      resultCredential(completion)
    }
  }
  
  func prepareCredentialsPresentation(for domain: String, path: String,
                                      resultCredential: ((String) -> Void)?) {
    Logger.module.debug("skus prepareCredentialsPresentation")
    sku.prepareCredentialsPresentation(domain, path: path) { credential in
      if !credential.isEmpty {
        if let vpnCredential = BraveSkusWebHelper.fetchVPNCredential(credential, domain: domain) {
          Preferences.VPN.skusCredential.value = credential
          Preferences.VPN.skusCredentialDomain.value = domain
          Preferences.VPN.expirationDate.value = vpnCredential.expirationDate
          
          BraveVPN.setCustomVPNCredential(vpnCredential)
        }
      } else {
        Logger.module.debug("skus empty credential from prepareCredentialsPresentation call")
      }
      
      resultCredential?(credential)
    }
  }
  
  func credentialSummary(for domain: String, resultJSON: @escaping (Any?) -> Void) {
    sku.credentialSummary(domain) { [weak self] completion in
      do {
        Logger.module.debug("skus credentialSummary")
        
        guard let data = completion.data(using: .utf8) else {
          resultJSON(nil)
          return
        }
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let credentialSummaryJson = try jsonDecoder.decode(CredentialSummary.self, from: data)
        
        if credentialSummaryJson.isValid {
          
          if Preferences.VPN.skusCredential.value == nil {
            Logger.module.debug("The credential does NOT exists, calling prepareCredentialsPresentation")
            self?.prepareCredentialsPresentation(for: domain, path: "*", resultCredential: nil)
          } else {
            Logger.module.debug("The credential exists, NOT calling prepareCredentialsPresentation")
          }
        } else {
          if !credentialSummaryJson.active {
            Logger.module.debug("The credential summary is not active")
          }
          
          if credentialSummaryJson.remainingCredentialCount <= 0 {
            Logger.module.debug("The credential summary does not have any remaining credentials")
          }
        }
        
        resultJSON(json)
      } catch {
        resultJSON(nil)
        Logger.module.error("refrshOrder: Failed to decode json: \(error.localizedDescription)")
      }
    }
  }
  
  private struct CredentialSummary: Codable {
    let expiresAt: Date
    let active: Bool
    let remainingCredentialCount: Int
    // The json for credential summary has additional fields. They are not used in the app at the moment.
    
    var isValid: Bool {
      active && remainingCredentialCount > 0
    }
    
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.active = try container.decode(Bool.self, forKey: .active)
      self.remainingCredentialCount = try container.decode(Int.self, forKey: .remainingCredentialCount)
      guard let expiresAt =
              BraveSkusWebHelper.milisecondsOptionalDate(from: try container.decode(String.self, forKey: .expiresAt)) else {
        throw DecodingError.typeMismatch(Data.self, .init(codingPath: [],
                                                            debugDescription: "Failed to decode Data from String"))
      }
      
      self.expiresAt = expiresAt
    }
  }
}
