//
//  EthereumProvider.swift
//  ZKSync
//
//  Created by Eugene Belyakov on 17/01/2021.
//

import Foundation
import BigInt
import web3swift
import PromiseKit

public enum EthereumProviderError: Error {
    case invalidAddress
    case invalidTokenAddress
    case internalError
}

public class EthereumProvider {

    let web3: web3

    let zkSync: ZkSync

    var ethereumAddress: EthereumAddress

    var keystore: AbstractKeystore

    init(web3: web3,
         keystore: AbstractKeystore,
         ethereumAddress: EthereumAddress,
         zkSync: ZkSync) {
        self.web3 = web3
        self.zkSync = zkSync

        self.keystore = keystore
        self.ethereumAddress = ethereumAddress

        if let keystore = keystore as? EthereumKeystoreV3 {
            let keystoreManager = KeystoreManager([keystore])
            self.web3.addKeystoreManager(keystoreManager)
        } else if let keystore = keystore as? BIP32Keystore {
            let keystoreManager = KeystoreManager([keystore])
            self.web3.addKeystoreManager(keystoreManager)
        }
    }

    public func approveDeposits(token: Token, limit: BigUInt?) -> Promise<TransactionSendingResult> {
        guard let erc20ContractAddress = EthereumAddress(token.address) else {
            return .init(error: EthereumProviderError.invalidTokenAddress)
        }
        let erc20 = ERC20(web3: self.web3, provider: web3.provider, address: erc20ContractAddress)
        let maxApproveAmount = BigUInt.two.power(256) - 1
        let amount = limit?.description ?? maxApproveAmount.description

        do {
            let tx = try erc20.approve(from: ethereumAddress,
                                       spender: ethereumAddress,
                                       amount: amount)
            return tx.sendPromise()
        } catch {
            return .init(error: error)
        }
    }

    public func transfer(token: Token, amount: BigUInt, to: String) -> Promise<TransactionSendingResult> {
        let tx: WriteTransaction
        do {
            if token.isETH {
                tx = try self.transferEth(amount: amount, to: to)
            } else {
                tx = try self.transferERC20(token: token, amount: amount, to: to)
            }
            return tx.sendPromise()
        } catch {
            return .init(error: error)
        }
    }

    private func transferEth(amount: BigUInt, to: String) throws -> WriteTransaction {
        guard let toAddress = EthereumAddress(to) else {
            throw EthereumProviderError.invalidAddress
        }
        guard let tx = web3.eth.sendETH(from: ethereumAddress,
                                        to: toAddress,
                                        amount: amount.description,
                                        units: .wei) else {
            throw EthereumProviderError.internalError
        }
        return tx
    }

    private func transferERC20(token: Token, amount: BigUInt, to: String) throws -> WriteTransaction {
        guard let toAddress = EthereumAddress(to) else {
            throw EthereumProviderError.invalidAddress
        }
        guard let erc20ContractAddress = EthereumAddress(token.address) else {
            throw EthereumProviderError.invalidTokenAddress
        }
        guard let tx = web3.eth.sendERC20tokensWithKnownDecimals(tokenAddress: erc20ContractAddress,
                                                                 from: ethereumAddress,
                                                                 to: toAddress,
                                                                 amount: amount) else {
            throw EthereumProviderError.internalError
        }
        return tx
    }

    public func deposit(token: Token, amount: BigUInt, userAddress: String) -> Promise<TransactionSendingResult> {
        guard let userAddress = EthereumAddress(userAddress) else {
            return .init(error: EthereumProviderError.invalidAddress)
        }
        if token.isETH {
            return zkSync.depositETH(address: userAddress, value: amount)
        } else {
            guard let tokenAddress = EthereumAddress(token.address) else {
                return .init(error: EthereumProviderError.invalidTokenAddress)
            }
            return zkSync.depositERC20(tokenAddress: tokenAddress, amount: amount, userAddress: userAddress)
        }
    }

    public func fullExit(token: Token, accountId: UInt32) -> Promise<TransactionSendingResult> {
        guard let tokenAddress = EthereumAddress(token.address) else {
            return .init(error: EthereumProviderError.invalidTokenAddress)
        }
        return zkSync.requestFullExit(tokenAddress: tokenAddress, accountId: accountId)
    }

    public func setAuthPubkeyHash(pubKeyhash: String, nonce: UInt32) -> Promise<TransactionSendingResult> {
        let data = Data(hex: pubKeyhash)
        return zkSync.setAuthPubkeyHash(pubKeyHash: data, nonce: nonce)
    }

    public func isDepositApproved(token: Token, threshold: BigUInt?) throws -> Bool {
        guard let erc20ContractAddress = EthereumAddress(token.address) else {
            throw EthereumProviderError.invalidTokenAddress
        }
        let erc20 = ERC20(web3: self.web3, provider: web3.provider, address: erc20ContractAddress)
        let allowance = try erc20.getAllowance(originalOwner: ethereumAddress,
                                               delegate: zkSync.contractAddress)
        let defaultThreshold = BigUInt.two.power(255)
        return allowance > (threshold ?? defaultThreshold)
    }

    public func getBalance() -> Promise<BigUInt> {
        web3.eth.getBalancePromise(address: ethereumAddress)
    }

    public func getNonce() -> Promise<BigUInt> {
        web3.eth.getTransactionCountPromise(address: ethereumAddress)
    }

    public func isOnChainAuthPubkeyHashSet(nonce: UInt32) -> Promise<Bool> {
        firstly {
            zkSync.authFacts(senderAddress: ethereumAddress, nonce: nonce)
        }.map(on: web3.requestDispatcher.queue) { (data) in
            !data.isEmpty
        }
    }
}

extension TransactionOptions {

    init(amount: BigUInt, from: EthereumAddress) {
        self = TransactionOptions.defaultOptions
        self.value = amount
        self.from = from
    }
}
