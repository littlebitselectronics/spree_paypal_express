require 'spec_helper'

module Spree
  describe CheckoutController do
    render_views
    let(:token) { 'EC-2OPN7UJGFWK9OYFV' }
    let(:order) { create(:order_with_line_items, state: 'payment') }
    let(:shipping_method) { create(:shipping_method) }
    let(:order_total) { (order.total * 100).to_i }
    let(:gateway_provider) { double(ActiveMerchant::Billing::PaypalExpressGateway) }
    let(:redirect_url) { "https://www.sandbox.paypal.com/cgi-bin/webscr?cmd=_express-checkout&token=#{token}&useraction=commit" }
    let(:paypal_gateway) do
      double(BillingIntegration::PaypalExpress,
             id: 123,
             payment_profiles_supported?: false,
             preferred_cart_checkout: false,
             preferred_review: false,
             preferred_no_shipping: true,
             provider: gateway_provider,
             preferred_currency: 'US',
             preferred_allow_guest_checkout: true
            )
    end

    let(:details_for_response) do
      double(ActiveMerchant::Billing::PaypalExpressResponse,
             success?: true,
             params:  { 'payer' => order.user.email, 'payer_id' => 'FWRVKNRRZ3WUC' },
             address: {}
            )
    end

    let(:purchase_response) do
      double(ActiveMerchant::Billing::PaypalExpressResponse,
             success?: true,
             authorization: 'ABC123456789',
             params: { 'payer' => order.user.email, 'payer_id' => 'FWRVKNRRZ3WUC', 'gross_amount' => order.total, 'payment_status' => 'Completed' },
             avs_result: 'F',
             to_yaml: 'fake'
            )
    end

    before do
      controller.stub(current_order: order, check_authorization: true, spree_current_user: order.user)
      order.stub(checkout_allowed?: true, completed?: false, payment_method: paypal_gateway)
      order.stub(tax_total: 0)
      order.update!
    end

    it 'understand paypal routes' do
      skip('Unknown how to make this work within the scope of an engine again')

      assert_routing("/orders/#{order.number}/checkout/paypal_payment", controller: 'checkout', action: 'paypal_payment', order_id: order.number)
      assert_routing("/orders/#{order.number}/checkout/paypal_confirm", controller: 'checkout', action: 'paypal_confirm', order_id: order.number)
    end

    context 'paypal_checkout from cart' do
      skip 'feature not implemented'
    end

    context 'paypal_payment without auto_capture' do
      before { Spree::Config.set(auto_capture: false) }

      it 'setup an authorize transaction and redirect to sandbox' do
        Spree::PaymentMethod.should_receive(:find).at_least(1).with('123').and_return(paypal_gateway)

        gateway_provider.should_receive(:redirect_url_for).with(token, review: false).and_return redirect_url
        paypal_gateway.provider.should_receive(:setup_authorization).with(order_total, anything).and_return(double(success?: true, token: token))

        get :paypal_payment, order_id: order.number, payment_method_id: '123'

        expect(response).to redirect_to("https://www.sandbox.paypal.com/cgi-bin/webscr?cmd=_express-checkout&token=#{assigns[:ppx_response].token}&useraction=commit")
      end
    end

    context 'paypal_payment with auto_capture' do
      before { Spree::Config.set(auto_capture: true) }

      it 'setup a purchase transaction and redirect to sandbox' do
        Spree::PaymentMethod.should_receive(:find).at_least(1).with('123').and_return(paypal_gateway)

        gateway_provider.should_receive(:redirect_url_for).with(token, review: false).and_return redirect_url
        paypal_gateway.provider.should_receive(:setup_purchase).with(order_total, anything).and_return(double(success?: true, token: token))

        get :paypal_payment, order_id: order.number, payment_method_id: '123'

        expect(response).to redirect_to("https://www.sandbox.paypal.com/cgi-bin/webscr?cmd=_express-checkout&token=#{assigns[:ppx_response].token}&useraction=commit")
      end
    end

    context 'paypal_confirm' do
      before do
        Spree::PaymentMethod.should_receive(:find).at_least(1).with('123').and_return(paypal_gateway)
        order.stub(:payment_method).and_return paypal_gateway
      end

      context 'with auto_capture and no review' do
        before do
          Spree::Config.set(auto_capture: true)
          paypal_gateway.stub(preferred_review: false)
        end

        it 'capture payment' do
          paypal_gateway.provider.should_receive(:details_for).with(token).and_return(details_for_response)

          paypal_gateway.provider.should_receive(:purchase).with(order_total, anything).and_return(purchase_response)

          get :paypal_confirm, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          response.should redirect_to spree.order_path(order)

          expect(order.state).to eq('complete')
          expect(order.completed_at).not_to be_nil
          expect(order.payments.count).to eq(1)
          expect(order.payment_state).to eq('paid')
        end
      end

      context 'with review' do
        before do
          paypal_gateway.stub(preferred_review: true, payment_profiles_supported?: true)
          order.stub(confirmation_required?: true)
          order.stub_chain(:payment, :payment_method, payment_profiles_supported?: true)
          order.stub_chain(:payment, :source, type: 'Spree:PaypalAccount')
        end

        it 'render review' do
          paypal_gateway.provider.should_receive(:details_for).with(token).and_return(details_for_response)

          get :paypal_confirm, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          response.should render_template('spree/shared/paypal_express_confirm')
          expect(order.state).to eq('confirm')
        end

        it 'does not change order state on multiple call' do
          paypal_gateway.provider.should_receive(:details_for).twice.with(token).and_return(details_for_response)

          get :paypal_confirm, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'
          get :paypal_confirm, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'
          expect(order.state).to eq('confirm')
        end
      end

      context 'with review and shipping update' do
        before do
          paypal_gateway.stub(preferred_review: true)
          paypal_gateway.stub(preferred_no_shipping: false)
          paypal_gateway.stub(payment_profiles_supported?: true)
          order.stub(confirmation_required?: true)
          order.stub_chain(:payment, :payment_method, payment_profiles_supported?: true)
          order.stub_chain(:payment, :source, type: 'Spree:PaypalAccount')
          details_for_response.stub(params: details_for_response.params.merge('first_name' => 'Dr.', 'last_name' => 'Evil'),
                                    address: { 'address1' => 'Apt. 187', 'address2' => 'Some Str.', 'city' => 'Chevy Chase', 'country' => 'US', 'zip' => '20815', 'state' => 'MD' }
                                   )
        end

        it 'update ship_address and render review' do
          paypal_gateway.provider.should_receive(:details_for).with(token).and_return(details_for_response)

          get :paypal_confirm, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          expect(order.ship_address.address1).to eq('Apt. 187')
          response.should render_template('spree/shared/paypal_express_confirm')
          expect(order.state).to eq('confirm')
        end
      end

      context 'with un-successful repsonse' do
        before { details_for_response.stub(success?: false) }

        it 'log error and redirect to payment step' do
          paypal_gateway.provider.should_receive(:details_for).with(token).and_return(details_for_response)

          controller.should_receive(:gateway_error).with(details_for_response)

          get :paypal_confirm, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          response.should redirect_to spree.edit_order_checkout_path(order, state: 'payment')
        end
      end
    end

    context 'paypal_finish' do
      let(:paypal_account) do
        PaypalAccount.new(
          payer_id: 'FWRVKNRRZ3WUC',
          email: order.email
        )
      end

      let(:authorize_response) do
        double(ActiveMerchant::Billing::PaypalExpressResponse,
               success?: true,
               authorization: 'ABC123456789',
               params: { 'payer' => order.user.email, 'payer_id' => 'FWRVKNRRZ3WUC', 'gross_amount' => order.total, 'payment_status' => 'Pending' },
               avs_result: 'F',
               to_yaml: 'fake'
              )
      end

      before do
        Spree::PaymentMethod.should_receive(:find).at_least(1).with('123').and_return(paypal_gateway)
        Spree::PaypalAccount.should_receive(:find_by_payer_id).with('FWRVKNRRZ3WUC').and_return(paypal_account)
      end

      context 'with auto_capture' do
        before { Spree::Config.set(auto_capture: true) }

        it 'capture payment' do
          paypal_gateway.provider.should_receive(:purchase).with(order_total, anything).and_return(purchase_response)

          get :paypal_finish, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          response.should redirect_to spree.order_path(order)

          order.reload
          order.update!
          expect(order.payments.count).to eq(1)
          expect(order.payment_state).to eq('paid')
        end
      end

      context 'with auto_capture and pending(echeck) response' do
        before do
          Spree::Config.set(auto_capture: true)
          purchase_response.params['payment_status'] = 'pending'
        end

        it 'authorize payment' do
          paypal_gateway.provider.should_receive(:purchase).with(order_total, anything).and_return(purchase_response)

          get :paypal_finish, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          response.should redirect_to spree.order_path(order)

          order.reload
          order.update!
          expect(order.payments.count).to eq(1)
          expect(order.payment_state).to eq('balance_due')
          expect(order.payments.first.state).to eq('pending')
        end
      end

      context 'without auto_capture' do
        before { Spree::Config.set(auto_capture: false) }

        it 'authorize payment' do
          paypal_gateway.provider.should_receive(:authorize).with(order_total, anything).and_return(authorize_response)

          get :paypal_finish, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          response.should redirect_to spree.order_path(order)

          order.reload
          order.update!
          expect(order.payments.count).to eq(1)
          expect(order.payment_state).to eq('balance_due')
          expect(order.payments.first.state).to eq('pending')
        end
      end

      context 'with un-successful repsonse' do
        before do
          Spree::Config.set(auto_capture: true)
          purchase_response.stub(success?: false)
        end

        it 'log error and redirect to payment step' do
          paypal_gateway.provider.should_receive(:purchase).with(order_total, anything).and_return(purchase_response)

          controller.should_receive(:gateway_error).with(purchase_response)

          get :paypal_finish, order_id: order.number, payment_method_id: '123', token: token, PayerID: 'FWRVKNRRZ3WUC'

          response.should redirect_to spree.edit_order_checkout_path(order, state: 'payment')

          order.reload
          order.update!
          expect(order.payments.count).to eq(1)
          expect(order.payments.first.state).to eq('failed')
        end
      end
    end

    context '#fixed_opts' do
      xit 'returns hash containing basic settings' do
        I18n.locale = :fr
        opts = controller.send(:fixed_opts)
        expect(opts[:header_image]).to eq('http://demo.spreecommerce.com/assets/admin/bg/spree_50.png')
        expect(opts[:locale]).to eq('fr')
      end
    end

    context 'order_opts' do
      let(:order_confirm_url) do
        spree.paypal_confirm_order_checkout_url(order, payment_method_id: paypal_gateway.id, host: 'test.host')
      end

      let(:order_edit_url) do
        spree.edit_order_checkout_url(order, state: 'payment', host: 'test.host')
      end

      let(:subtotal) do
        ((order.item_total * 100) + (order.adjustments.select { |c| c.amount < 0 }.sum(&:amount) * 100)).to_i
      end

      before do
        controller.should_receive(:payment_method).at_least(1).and_return(paypal_gateway)
      end

      it 'return hash containing basic order details' do
        opts = controller.send(:order_opts, order, paypal_gateway.id, 'payment')

        expect(opts[:money]).to eq(order_total)
        expect(opts[:subtotal]).to eq((order.item_total * 100).to_i)
        expect(opts[:order_id]).to eq(order.number)
        expect(opts[:custom]).to eq(order.number)
        expect(opts[:handling]).to eq(0)
        expect(opts[:shipping]).to eq((order.ship_total * 100).to_i)

        expect(opts[:return_url]).to eq(order_confirm_url)
        expect(opts[:cancel_return_url]).to eq(order_edit_url)

        expect(opts[:items].count > 0).to be_truthy
        expect(opts[:items].count).to eq(order.line_items.count)
      end

      it 'include credits in returned hash' do
        order_total # need here so variable is set before credit is created.
        order.adjustments.create(label: 'Credit', amount: -1)
        order.update!
        opts = controller.send(:order_opts, order, paypal_gateway.id, 'payment')

        expect(opts[:money]).to eq(order_total - 100)
        expect(opts[:subtotal]).to eq(subtotal)

        expect(opts[:items].count).to eq(order.line_items.count + 1)
      end
    end

    describe '#paypal_site_opts' do
      it 'returns opts to allow guest checkout' do
        controller.should_receive(:payment_method).at_least(1).and_return(paypal_gateway)

        opts = controller.send(:paypal_site_opts)
        expect(opts[:allow_guest_checkout]).to be_truthy
      end
    end
  end
end
