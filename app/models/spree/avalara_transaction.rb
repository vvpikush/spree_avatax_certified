require 'logging'
require_dependency 'spree/order'

module Spree
  class AvalaraTransaction < ActiveRecord::Base
    AVALARA_TRANSACTION_LOGGER = AvataxHelper::AvataxLog.new('post_order_to_avalara', __FILE__)

    belongs_to :order
    belongs_to :return_authorization
    validates :order, presence: true
    validates :order_id, uniqueness: true
    has_many :adjustments, as: :source

    def lookup_avatax
      post_order_to_avalara(false, 'SalesOrder')
    end

    def commit_avatax(invoice_dt=nil)
      if tax_calculation_enabled?
        post_order_to_avalara(false, invoice_dt)
      else
        { TotalTax: '0.00' }
      end
    end

    def commit_avatax_final(invoice_dt=nil)
      if document_committing_enabled?
        if tax_calculation_enabled?
          post_order_to_avalara(true, invoice_dt)
        else
          { TotalTax: '0.00' }
        end
      else
        AVALARA_TRANSACTION_LOGGER.debug 'avalara document committing disabled'
        'avalara document committing disabled'
      end
    end

    def cancel_order
      cancel_order_to_avalara('SalesInvoice', 'DocVoided')
    end

    private

    def cancel_order_to_avalara(doc_type = 'SalesInvoice', cancel_code = 'DocVoided')
      AVALARA_TRANSACTION_LOGGER.info('cancel order to avalara')

      cancelTaxRequest = {
        :CompanyCode => Spree::Config.avatax_company_code,
        :DocType => doc_type,
        :DocCode => order.number,
        :CancelCode => cancel_code
      }

      AVALARA_TRANSACTION_LOGGER.debug cancelTaxRequest

      mytax = TaxSvc.new
      cancelTaxResult = mytax.cancel_tax(cancelTaxRequest)

      AVALARA_TRANSACTION_LOGGER.debug cancelTaxResult

      if cancelTaxResult == 'error in Tax' then
        return 'Error in Tax'
      else
        if cancelTaxResult['ResultCode'] = 'Success'
          AVALARA_TRANSACTION_LOGGER.debug cancelTaxResult
          return cancelTaxResult
        end
      end
    end

    def post_order_to_avalara(commit=false, invoice_detail=nil)
      AVALARA_TRANSACTION_LOGGER.info('post order to avalara')

      avatax_address = SpreeAvataxCertified::Address.new(order)
      avatax_line = SpreeAvataxCertified::Line.new(order, invoice_detail)

      AVALARA_TRANSACTION_LOGGER.debug avatax_address
      AVALARA_TRANSACTION_LOGGER.debug avatax_line

      response = avatax_address.validate

      unless response.nil?
        if response['ResultCode'] == 'Success'
          AVALARA_TRANSACTION_LOGGER.info('Address Validation Success')
        else
          AVALARA_TRANSACTION_LOGGER.info('Address Validation Failed')
        end
      end

      taxoverride = {}

      order_num = nil
      order_date = nil

      if invoice_detail == 'ReturnInvoice' || invoice_detail == 'ReturnOrder'
        taxoverride[:TaxOverrideType] = 'TaxDate'
        taxoverride[:Reason] = 'Adjustment for return'
        taxoverride[:TaxDate] = Date.today.strftime('%F')
        taxoverride[:TaxAmount] = '0'
        order_num = order.number.to_s + ':' + self.id.to_s
        order_date = order.completed_at.strftime('%F')
      end

      gettaxes = {
        :CustomerCode => order.user ? order.user.id : 'Guest',
        :DocDate => order_date ? order_date : Date.today.strftime('%F'),

        :CompanyCode => Spree::Config.avatax_company_code,
        :CustomerUsageType => order.user ? order.user.avalara_entity_use_code.try(:use_code) : '',
        :ExemptionNo => order.user.try(:exemption_number),
        :Client =>  AVATAX_CLIENT_VERSION || 'SpreeExtV2.3',
        :DocCode => order.number,

        :Discount => order.promo_total.to_s,

        :ReferenceCode => order_num ? order_num : order.number,
        :DetailLevel => 'Tax',
        :Commit => commit,
        :DocType => invoice_detail ? invoice_detail : 'SalesInvoice',
        :Addresses => avatax_address.addresses,
        :Lines => avatax_line.lines
      }

      unless taxoverride.empty?
        gettaxes[:TaxOverride] = taxoverride
      end

      AVALARA_TRANSACTION_LOGGER.debug gettaxes

      mytax = TaxSvc.new

      AVALARA_TRANSACTION_LOGGER.info '********** hitting the api'

      getTaxResult = mytax.get_tax(gettaxes)

      AVALARA_TRANSACTION_LOGGER.debug getTaxResult

      if getTaxResult == 'error in Tax' then
        @myrtntax = { TotalTax: '0.00' }
      else
        if getTaxResult['ResultCode'] = 'Success'
          AVALARA_TRANSACTION_LOGGER.info 'total tax'
          AVALARA_TRANSACTION_LOGGER.debug getTaxResult['TotalTax'].to_s
          @myrtntax = getTaxResult
        end
      end
      return @myrtntax
    end

    def document_committing_enabled?
      Spree::Config.avatax_document_commit
    end

    def tax_calculation_enabled?
      Spree::Config.avatax_tax_calculation
    end
  end
end
